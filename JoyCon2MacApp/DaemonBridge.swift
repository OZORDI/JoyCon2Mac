import Foundation
import Combine
import AppKit
import Darwin

struct ControllerState: Identifiable {
    let id: String
    var side: String
    var name: String
    var macAddress: String
    var isConnected: Bool
    var status: String
    var batteryVoltage: Double
    var batteryCurrent: Double
    var batteryTemperature: Double
    var batteryPercentage: Double
    var buttons: UInt32
    var leftButtons: UInt32
    var rightButtons: UInt32
    var leftStickX: Int16
    var leftStickY: Int16
    var rightStickX: Int16
    var rightStickY: Int16
    var gyroX: Double
    var gyroY: Double
    var gyroZ: Double
    var accelX: Double
    var accelY: Double
    var accelZ: Double
    var mouseX: Int16
    var mouseY: Int16
    var mouseDistance: Int16
    var triggerL: UInt8
    var triggerR: UInt8
    var packetCount: UInt32
    var mouseMode: MouseMode
    var mouseSource: MouseSource
    var mouseActiveSide: String
    var rssi: Int
}

enum MouseMode: Int {
    // Raw values MUST match the daemon's C++ MouseMode enum in MouseEmitter.h:
    //   0 = OFF, 1 = FAST, 2 = NORMAL, 3 = SLOW
    // Before this alignment the picker silently sent the wrong numeric code
    // (Swift had slow=1 where the daemon wanted fast=1) so picking "Slow"
    // actually enabled "Fast" on the daemon side.
    case off = 0
    case fast = 1
    case normal = 2
    case slow = 3

    var description: String {
        switch self {
        case .off: return "Off"
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .slow: return "Slow"
        }
    }

    var multiplier: Double {
        switch self {
        case .off: return 0.0
        case .slow: return 0.3
        case .normal: return 0.6
        case .fast: return 1.0
        }
    }
}

enum MouseSource: Int {
    // Raw values match the daemon's C++ MouseSource enum.
    case auto = 0
    case left = 1
    case right = 2

    var description: String {
        switch self {
        case .auto: return "Auto"
        case .left: return "Left Joy-Con"
        case .right: return "Right Joy-Con"
        }
    }
}

struct NFCTag: Identifiable {
    let id = UUID()
    var uid: String
    var type: String
    var data: Data
    var timestamp: Date
}

// Design notes (frozen-UI postmortem)
//
// The UI was freezing because the main thread was doing:
//   1. File I/O (tailing daemon.jsonl every 100 ms)
//   2. JSON parsing for ~240 state events per second
//   3. Appending to a Published string (invalidating every view)
//   4. SwiftUI view updates
//
// Throttling step 3 in isolation does NOT help: steps 1-2 still thrash the
// main run loop. SwiftUI cannot repaint. Apple's Combine / Concurrency docs
// (https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app)
// explicitly recommend running data ingest on a background queue and
// publishing to main via a throttled pipeline.
//
// So the real fix is architectural:
//   - Log tailing + JSON parsing run on a dedicated serial background queue.
//   - State events are gated at display-rate cadence on that queue. The old
//     15 Hz gate was safe but visibly laggy for button/stick tester UI.
//   - Only the gated, pre-built ControllerState is hopped onto main.
//   - Telemetry log lines go to TelemetryStore, which batch-flushes to main
//     every 200 ms. Settings/Logs views are the only subscribers.
class DaemonBridge: ObservableObject {
    static let shared = DaemonBridge()

    @Published var controllers: [ControllerState] = []
    @Published var nfcTags: [NFCTag] = []
    @Published var isDaemonRunning = false
    // Kept for source-compat with older views. Never mutated from the
    // packet firehose now; only on driver-install result.
    @Published var driverInstallStatus: String = ""
    @Published var stateRevision: UInt64 = 0
    @Published var findingLeftJoyCon = false
    @Published var findingRightJoyCon = false

    // Background queue that owns parsing, file tailing, and throttling.
    // Nothing on this queue touches @Published state directly.
    private let ingestQueue = DispatchQueue(label: "local.joycon2mac.ingest", qos: .userInitiated)

    private var daemonProcess: Process?
    private var daemonApplication: NSRunningApplication?
    private var outputPipe: Pipe?
    private var pendingOutput = ""
    // Per-controller rate limiter (accessed only on ingestQueue).
    private var lastIngestTime: [String: Date] = [:]
    private let controllerUpdateInterval: TimeInterval = 1.0 / 120.0
    private var shouldRestartAfterTermination = false
    private var logPollTimer: DispatchSourceTimer?
    private let logPollInterval: DispatchTimeInterval = .milliseconds(8)
    private var daemonLogPath: URL?
    private var daemonLogOffset: UInt64 = 0
    // Path the daemon polls for GUI → daemon commands (mouse-mode toggle etc).
    // Stored as URL so we can append with NSFileHandle without re-resolving
    // the Application Support directory each time.
    private var daemonControlPath: URL?
    // Diagnostic counters bumped on ingestQueue; snapshotted for logs.
    private var ingestPacketCountLeft: UInt64 = 0
    private var ingestPacketCountRight: UInt64 = 0
    private var ingestPacketDropLeft: UInt64 = 0
    private var ingestPacketDropRight: UInt64 = 0

    // End-to-end input trace. The daemon writes [BLE->DEC L/R] (what the
    // decoder produced from the BLE packet) and [HID-TX] (what gets
    // shipped to the DriverKit extension → Chrome/games) into
    // ~/Library/Application Support/JoyCon2Mac/input-trace.log. We append
    // [UI R] / [UI L] lines to the same file so you can diff all three
    // pipeline stages in one place:
    //
    //   [BLE->DEC R]   = physical stick value the daemon just decoded
    //   [UI R]         = value the GUI ingested from JSON and will display
    //   [HID-TX] RS=…  = value the daemon shipped to the dext (→ Chrome)
    //
    // If [BLE->DEC R] shows motion and [UI R] doesn't, the JSON emitter
    // is broken. If [UI R] shows motion and [HID-TX] doesn't, something
    // in the gamepad-report build path is dropping it. If [HID-TX] is
    // correct and games still see nothing, the dext/descriptor is the
    // problem. Change-triggered, zero noise when idle.
    private var traceFileHandle: FileHandle?
    private var lastTraceRightX: Int16 = .min
    private var lastTraceRightY: Int16 = .min
    private var lastTraceLeftX: Int16 = .min
    private var lastTraceLeftY: Int16 = .min

    private func openTraceFile(at url: URL) {
        // Daemon opens the same file in append mode. Trust the daemon to
        // create it; we just re-open for append on our side so both
        // processes can write without clobbering each other's lines. No
        // cross-process locking because each process writes whole lines
        // (<256 B) which POSIX append-mode treats atomically.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        traceFileHandle = try? FileHandle(forWritingTo: url)
        try? traceFileHandle?.seekToEnd()
    }

    private func writeTrace(_ line: String) {
        guard let fh = traceFileHandle else { return }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? fh.write(contentsOf: data)
    }

    private init() {
        startDaemon()
    }

    deinit {
        stopDaemon()
    }

    // MARK: - Lifecycle

    // Generation counter — every time we (re)start, we bump this. Any
    // stale termination callback from a previously-stopped daemon checks
    // its captured generation against the current one and ignores itself
    // if they don't match. That kept a dying Stop from nuking a fresh Start.
    private var daemonGeneration: UInt64 = 0

    func startDaemon() {
        if let daemonProcess, daemonProcess.isRunning {
            isDaemonRunning = true
            return
        }
        if let daemonApplication, !daemonApplication.isTerminated {
            isDaemonRunning = true
            return
        }

        // Belt-and-braces: kill any stragglers of our helper bundle before
        // starting. NSWorkspace.openApplication will otherwise reuse the
        // dying instance and the new Start silently no-ops.
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "local.joycon2mac.daemon") {
            Darwin.kill(app.processIdentifier, SIGKILL)
        }

        shouldRestartAfterTermination = false
        daemonProcess = nil
        daemonApplication = nil
        outputPipe = nil
        controllers.removeAll()
        ingestQueue.async { [weak self] in
            self?.lastIngestTime.removeAll()
        }
        daemonGeneration &+= 1
        let myGeneration = daemonGeneration

        if startBundledDaemonApp(generation: myGeneration) {
            return
        }

        let process = Process()
        let pipe = Pipe()

        let bundledDaemon = Bundle.main.resourceURL?.appendingPathComponent("joycon2mac")
        let siblingDaemon = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("joycon2mac")
        let devDaemon = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/bin/joycon2mac")

        let daemonPath: URL
        if let bundledDaemon = bundledDaemon,
           FileManager.default.isExecutableFile(atPath: bundledDaemon.path) {
            daemonPath = bundledDaemon
        } else if FileManager.default.isExecutableFile(atPath: siblingDaemon.path) {
            daemonPath = siblingDaemon
        } else {
            daemonPath = devDaemon
        }

        process.executableURL = daemonPath
        var processArguments = ["--json"]
        if UserDefaults.standard.bool(forKey: "sdlOnlyMode") {
            processArguments.append("--sdl-only")
        }
        process.arguments = processArguments
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let output = String(data: data, encoding: .utf8) else {
                return
            }
            self?.ingestQueue.async {
                self?.parseDaemonOutputOnIngestQueue(output)
            }
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                // If a newer generation has already started, this termination
                // belongs to an older instance. Swallow it.
                if myGeneration != self.daemonGeneration { return }
                let shouldRestart = self.shouldRestartAfterTermination
                self.shouldRestartAfterTermination = false
                self.daemonProcess = nil
                self.daemonApplication = nil
                self.outputPipe = nil
                self.stopLogPolling()
                self.isDaemonRunning = false
                if shouldRestart {
                    self.startDaemon()
                } else {
                    self.markControllersDisconnected(status: "daemonStopped")
                }
            }
        }

        do {
            try process.run()
            daemonProcess = process
            outputPipe = pipe
            isDaemonRunning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.sendStoredRailBindings()
            }
        } catch {
            TelemetryStore.shared.append("Failed to start daemon: \(error)")
        }
    }

    private func startBundledDaemonApp(generation: UInt64) -> Bool {
        guard let helperApp = Bundle.main.resourceURL?.appendingPathComponent("JoyCon2MacDaemon.app"),
              FileManager.default.fileExists(atPath: helperApp.path) else {
            return false
        }

        do {
            // Wait briefly for any previous helper processes to actually die
            // before relaunching. Without this, LaunchServices can refuse the
            // relaunch request or fold us into the still-dying instance, and
            // Start appears to do nothing.
            var attempts = 0
            while attempts < 10 {
                let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "local.joycon2mac.daemon")
                    .filter { !$0.isTerminated }
                if existing.isEmpty { break }
                for app in existing {
                    Darwin.kill(app.processIdentifier, SIGKILL)
                }
                Thread.sleep(forTimeInterval: 0.05)
                attempts += 1
            }

            let supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("JoyCon2Mac", isDirectory: true)
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let logPath = supportDir.appendingPathComponent("daemon.jsonl")
            try Data().write(to: logPath, options: .atomic)
            daemonLogPath = logPath
            daemonLogOffset = 0
            // Control-channel file. GUI writes one JSON command per line,
            // daemon polls. Truncate on start so stale commands from a
            // previous session don't get re-applied.
            let controlPath = supportDir.appendingPathComponent("control.jsonl")
            try Data().write(to: controlPath, options: .atomic)
            daemonControlPath = controlPath
            TelemetryStore.shared.setLogPath(logPath)
            // Open (shared-append) the same input-trace.log the daemon is
            // going to write [BLE->DEC] and [HID-TX] lines into. Our side
            // appends [UI R] / [UI L] lines on JSON ingest so a single
            // `tail -f` on this one file shows all three pipeline stages.
            let tracePath = supportDir.appendingPathComponent("input-trace.log")
            // Truncate so each session's trace starts clean.
            try? Data().write(to: tracePath, options: .atomic)
            openTraceFile(at: tracePath)
            controllers.removeAll()
            ingestQueue.async { [weak self] in
                self?.lastIngestTime.removeAll()
                self?.ingestPacketCountLeft = 0
                self?.ingestPacketCountRight = 0
                self?.ingestPacketDropLeft = 0
                self?.ingestPacketDropRight = 0
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = true
            // The daemon's change-triggered input trace is on by default and
            // mirrors to ~/Library/Application Support/JoyCon2Mac/input-trace.log
            // so you can just `tail -f` that file while playing. To turn it
            // off: edit the daemon args below and add "--no-debug-input".
            var arguments = [
                "--json",
                "--json-file", logPath.path,
                "--control-file", controlPath.path
            ]
            if UserDefaults.standard.bool(forKey: "sdlOnlyMode") {
                arguments.append("--sdl-only")
            }
            configuration.arguments = arguments

            isDaemonRunning = true
            startLogPolling()

            NSWorkspace.shared.openApplication(at: helperApp, configuration: configuration) { [weak self] app, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if generation != self.daemonGeneration { return }
                    if let error {
                        TelemetryStore.shared.append("Failed to start helper daemon: \(error)")
                        self.isDaemonRunning = false
                        self.stopLogPolling()
                        self.markControllersDisconnected(status: "daemonStopped")
                        return
                    }
                    self.daemonApplication = app
                    // Observe termination so we can flip the running flag
                    // if the helper dies unexpectedly. pollDaemonLog also
                    // catches this but the observer reacts faster.
                    if let app {
                        self.observeDaemonTermination(app: app, generation: generation)
                    }
                }
            }
            return true
        } catch {
            TelemetryStore.shared.append("Failed to prepare daemon log: \(error)")
            return false
        }
    }

    private var daemonTerminationObservation: NSKeyValueObservation?

    private func observeDaemonTermination(app: NSRunningApplication, generation: UInt64) {
        daemonTerminationObservation?.invalidate()
        daemonTerminationObservation = app.observe(\.isTerminated, options: [.new]) { [weak self] _, change in
            guard let self, change.newValue == true else { return }
            DispatchQueue.main.async {
                if generation != self.daemonGeneration { return }
                self.handleDaemonTerminated()
            }
        }
    }

    func stopDaemon() {
        isDaemonRunning = false
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        daemonTerminationObservation?.invalidate()
        daemonTerminationObservation = nil

        if let daemonApplication {
            let pid = daemonApplication.processIdentifier
            Darwin.kill(pid, SIGTERM)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if Darwin.kill(pid, 0) == 0 {
                    Darwin.kill(pid, SIGKILL)
                }
            }
            self.daemonApplication = nil
            stopLogPolling()
            markControllersDisconnected(status: "daemonStopped")
            return
        }

        guard let process = daemonProcess else {
            outputPipe = nil
            stopLogPolling()
            markControllersDisconnected(status: "daemonStopped")
            return
        }

        if process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [weak process] in
                if let process, process.isRunning {
                    process.interrupt()
                }
            }
        }
    }

    func restartDaemon() {
        if daemonApplication != nil {
            shouldRestartAfterTermination = true
            stopDaemon()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                if self?.shouldRestartAfterTermination == true {
                    self?.shouldRestartAfterTermination = false
                    self?.startDaemon()
                }
            }
        } else if let process = daemonProcess, process.isRunning {
            shouldRestartAfterTermination = true
            stopDaemon()
        } else {
            startDaemon()
        }
    }

    // MARK: - Log tailing (background)

    private func startLogPolling() {
        stopLogPolling()
        let timer = DispatchSource.makeTimerSource(queue: ingestQueue)
        timer.schedule(deadline: .now() + logPollInterval, repeating: logPollInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.pollDaemonLogOnIngestQueue()
        }
        logPollTimer = timer
        timer.resume()
    }

    private func stopLogPolling() {
        logPollTimer?.cancel()
        logPollTimer = nil
    }

    private func pollDaemonLogOnIngestQueue() {
        // Runs on ingestQueue.
        if let daemonApplication, daemonApplication.isTerminated {
            DispatchQueue.main.async { [weak self] in self?.handleDaemonTerminated() }
            return
        }

        guard let daemonLogPath else { return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: daemonLogPath.path),
              let fileSize = attributes[.size] as? UInt64 else {
            return
        }
        if fileSize < daemonLogOffset {
            daemonLogOffset = 0
        }
        guard fileSize > daemonLogOffset,
              let handle = try? FileHandle(forReadingFrom: daemonLogPath) else {
            return
        }
        do {
            try handle.seek(toOffset: daemonLogOffset)
            let data = handle.readDataToEndOfFile()
            daemonLogOffset = try handle.offset()
            try handle.close()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                parseDaemonOutputOnIngestQueue(output)
            }
        } catch {
            try? handle.close()
        }
    }

    // MARK: - Parsing (background)

    private func parseDaemonOutputOnIngestQueue(_ output: String) {
        // Runs on ingestQueue.
        //
        // Careful: on bursty input, doing `pendingOutput += output` followed
        // by repeated `range(of: "\n")` + `removeSubrange(...)` is O(n^2) on
        // Swift strings. A 50-line batch of ~120-byte JSONL records becomes
        // ~millions of char copies, which is what was stalling the ingest
        // queue and occasionally freezing the UI.
        //
        // Instead: split the incoming chunk on newlines first (linear), and
        // only carry the trailing partial line across batches.
        let combined = pendingOutput + output
        var lines = combined.components(separatedBy: "\n")
        // Last element is whatever came after the final '\n' (may be empty
        // if the daemon flushed a full line, or a partial line mid-write).
        pendingOutput = lines.removeLast()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parseDaemonLineOnIngestQueue(trimmed)
            }
        }

        // Defensive: if a pathological write left us with a very long
        // partial line, clamp it rather than let it grow unbounded.
        if pendingOutput.count > 64 * 1024 {
            pendingOutput = ""
        }
    }

    private func parseDaemonLineOnIngestQueue(_ line: String) {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8) else {
            TelemetryStore.shared.append(line)
            return
        }

        // Fast path: peek at "event" without full JSON parse so we can drop
        // state packets that are inside the display-rate throttle window.
        let maybeState = line.contains("\"event\":\"state\"")
        if maybeState {
            let side = extractStateSide(in: line) ?? "left"
            let now = Date()
            if let last = lastIngestTime[side], now.timeIntervalSince(last) < controllerUpdateInterval {
                if side == "right" { ingestPacketDropRight &+= 1 } else { ingestPacketDropLeft &+= 1 }
                return
            }
            lastIngestTime[side] = now
            if side == "right" { ingestPacketCountRight &+= 1 } else { ingestPacketCountLeft &+= 1 }
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String else {
            TelemetryStore.shared.append(line)
            return
        }

        switch event {
        case "daemon":
            let status = stringValue(object["status"], default: "unknown")
            let detail = stringValue(object["detail"], default: "")
            TelemetryStore.shared.append("[daemon] \(status)\(detail.isEmpty ? "" : " - \(detail)")")
            DispatchQueue.main.async { [weak self] in
                if status == "started" { self?.isDaemonRunning = true }
                else if status == "exiting" { self?.isDaemonRunning = false }
                else if status == "findJoyCon" { self?.applyFindStatus(detail) }
                else if status == "controlFile" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self?.sendStoredRailBindings()
                    }
                }
            }
        case "telemetry":
            let side = stringValue(object["side"], default: "left")
            let phase = stringValue(object["phase"], default: "unknown")
            let detail = stringValue(object["detail"], default: "")
            let name = stringValue(object["name"], default: "")
            TelemetryStore.shared.append("[\(side)] \(phase)\(name.isEmpty ? "" : " \(name)")\(detail.isEmpty ? "" : " - \(detail)")")
        case "controller":
            let snapshot = buildControllerStatus(from: object)
            pendingStatusSnapshots[snapshot.side] = snapshot
            scheduleMainApplyLocked()
        case "state":
            let snapshot = buildControllerState(from: object)
            // [RS-UI]/[UI L] — what the GUI just ingested and will render.
            // Change-triggered so idle frames don't spam the log. Compared
            // against [RS-DEC]/[UI L] (daemon decoder output) and [RS-TX]
            // (what got shipped toward the HID driver), it pinpoints where a
            // missing input is lost: decoder, IPC/JSON, UI, or dext.
            if snapshot.side == "right" {
                if snapshot.rightStickX != lastTraceRightX || snapshot.rightStickY != lastTraceRightY {
                    writeTrace(String(
                        format: "[RS-UI] RS=(%6d,%6d) LS=(%6d,%6d) btn=0x%06x",
                        snapshot.rightStickX, snapshot.rightStickY,
                        snapshot.leftStickX, snapshot.leftStickY,
                        snapshot.buttons))
                    lastTraceRightX = snapshot.rightStickX
                    lastTraceRightY = snapshot.rightStickY
                }
            } else {
                if snapshot.leftStickX != lastTraceLeftX || snapshot.leftStickY != lastTraceLeftY {
                    writeTrace(String(
                        format: "[UI L] LS=(%6d,%6d) RS=(%6d,%6d) btn=0x%06x",
                        snapshot.leftStickX, snapshot.leftStickY,
                        snapshot.rightStickX, snapshot.rightStickY,
                        snapshot.buttons))
                    lastTraceLeftX = snapshot.leftStickX
                    lastTraceLeftY = snapshot.leftStickY
                }
            }
            pendingStateSnapshots[snapshot.id] = snapshot
            scheduleMainApplyLocked()
        case "nfc":
            guard let uid = object["uid"] as? String else { return }
            let payloadHex = object["payload"] as? String ?? ""
            let tag = NFCTag(
                uid: uid,
                type: object["type"] as? String ?? "Vendor",
                data: dataFromHexString(payloadHex),
                timestamp: Date()
            )
            DispatchQueue.main.async { [weak self] in self?.nfcTags.insert(tag, at: 0) }
        default:
            return
        }
    }

    // Cheap extraction of "side" from a state JSON line without full decode.
    private func extractStateSide(in line: String) -> String? {
        if line.contains("\"side\":\"right\"") { return "right" }
        if line.contains("\"side\":\"left\"") { return "left" }
        return nil
    }

    // MARK: - Snapshot builders (background)

    private func buildControllerState(from object: [String: Any]) -> ControllerState {
        let side = stringValue(object["side"], default: "left")
        let normalizedSide = side == "right" ? "right" : "left"
        return ControllerState(
            id: normalizedSide,
            side: normalizedSide,
            name: normalizedSide == "right" ? "Joy-Con R" : "Joy-Con L",
            macAddress: normalizedSide == "right" ? "Right BLE peripheral" : "Left BLE peripheral",
            isConnected: true,
            status: "streaming",
            batteryVoltage: doubleValue(object["batteryVoltage"]),
            batteryCurrent: doubleValue(object["batteryCurrent"]),
            batteryTemperature: doubleValue(object["batteryTemperature"]),
            batteryPercentage: doubleValue(object["batteryPercentage"], default: -1),
            buttons: uint32Value(object["buttons"]),
            leftButtons: uint32Value(object["leftButtons"]),
            rightButtons: uint32Value(object["rightButtons"]),
            leftStickX: int16Value(object["leftStickX"]),
            leftStickY: int16Value(object["leftStickY"]),
            rightStickX: int16Value(object["rightStickX"]),
            rightStickY: int16Value(object["rightStickY"]),
            gyroX: doubleValue(object["gyroX"]),
            gyroY: doubleValue(object["gyroY"]),
            gyroZ: doubleValue(object["gyroZ"]),
            accelX: doubleValue(object["accelX"]),
            accelY: doubleValue(object["accelY"]),
            accelZ: doubleValue(object["accelZ"]),
            mouseX: int16Value(object["mouseX"]),
            mouseY: int16Value(object["mouseY"]),
            mouseDistance: int16Value(object["mouseDistance"]),
            triggerL: uint8Value(object["triggerL"]),
            triggerR: uint8Value(object["triggerR"]),
            packetCount: uint32Value(object["packetCount"]),
            mouseMode: MouseMode(rawValue: intValue(object["mouseMode"])) ?? .off,
            mouseSource: MouseSource(rawValue: intValue(object["mouseSource"])) ?? .auto,
            mouseActiveSide: stringValue(object["mouseActiveSide"], default: "right"),
            rssi: intValue(object["rssi"], default: 0)
        )
    }

    private struct ControllerStatusSnapshot {
        let side: String
        let status: String
        let message: String
        let name: String
        let isConnected: Bool
    }

    private func buildControllerStatus(from object: [String: Any]) -> ControllerStatusSnapshot {
        let side = stringValue(object["side"], default: "left")
        let normalizedSide = side == "right" ? "right" : "left"
        let rawStatus = stringValue(object["status"], default: "scanning")
        let name = stringValue(
            object["name"],
            default: normalizedSide == "right" ? "Joy-Con R" : "Joy-Con L"
        )
        let message = stringValue(object["message"], default: "")
        let connectedStatuses = ["bleConnected", "servicesReady", "initializing", "ready", "streaming", "commandTimeout"]
        return ControllerStatusSnapshot(
            side: normalizedSide,
            status: rawStatus,
            message: message,
            name: name,
            isConnected: connectedStatuses.contains(rawStatus)
        )
    }

    // MARK: - Main-thread appliers
    //
    // We coalesce snapshots on the ingest queue into a small dictionary and
    // flush to the Published array at display-rate cadence. Gamepad/mouse
    // tester feedback must feel immediate, but we still avoid one main-thread
    // publish per BLE packet.
    private var pendingStateSnapshots: [String: ControllerState] = [:]
    private var pendingStatusSnapshots: [String: ControllerStatusSnapshot] = [:]
    private var mainApplyScheduled: Bool = false
    private let mainApplyInterval: TimeInterval = 1.0 / 120.0

    // Picker flicker guard. When the user picks a new mouseMode or
    // mouseSource, the daemon takes up to ~200 ms to read the control file,
    // apply it, and start echoing the new value in state events. State
    // packets from before the apply still carry the OLD value, so without
    // a guard the Picker bounces: user picks Fast -> optimistic UI shows
    // Fast -> a stale state packet arrives with Slow and overrides it ->
    // daemon finally applies the command -> state packets now say Fast.
    //
    // We keep the pending (user-chosen) value for `pendingEchoWindow`
    // seconds. Within that window, any incoming state snapshot with a
    // DIFFERENT value is assumed to be stale and locally overridden to the
    // pending value before being applied. After the window expires, or as
    // soon as we see a state packet that matches the pending value, the
    // guard is released.
    private var pendingMouseMode: MouseMode?
    private var pendingMouseModeDeadline: Date?
    private var pendingMouseSource: MouseSource?
    private var pendingMouseSourceDeadline: Date?
    private let pendingEchoWindow: TimeInterval = 0.6

    private func scheduleMainApplyLocked() {
        // Called on ingestQueue.
        if mainApplyScheduled { return }
        mainApplyScheduled = true
        let deadline = DispatchTime.now() + mainApplyInterval
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            self?.flushPendingToMain()
        }
    }

    private func flushPendingToMain() {
        // Called on main. Move ingest-side pending dicts over in one hop.
        let (states, statuses): ([String: ControllerState], [String: ControllerStatusSnapshot]) = ingestQueue.sync {
            let s = pendingStateSnapshots
            let u = pendingStatusSnapshots
            pendingStateSnapshots.removeAll(keepingCapacity: true)
            pendingStatusSnapshots.removeAll(keepingCapacity: true)
            mainApplyScheduled = false
            return (s, u)
        }

        if states.isEmpty && statuses.isEmpty { return }

        var updated = controllers
        var changed = false

        for (_, status) in statuses {
            if let index = updated.firstIndex(where: { $0.id == status.side }) {
                if updated[index].isConnected != status.isConnected {
                    updated[index].isConnected = status.isConnected
                    changed = true
                }
                if shouldReplaceStatus(current: updated[index].status, incoming: status.status) {
                    updated[index].status = status.status
                    changed = true
                }
                if !status.name.isEmpty {
                    updated[index].name = status.side == "right" ? "Joy-Con R" : "Joy-Con L"
                    updated[index].macAddress = status.message.isEmpty ? status.name : status.message
                    changed = true
                }
            } else {
                updated.append(
                    ControllerState(
                        id: status.side,
                        side: status.side,
                        name: status.side == "right" ? "Joy-Con R" : "Joy-Con L",
                        macAddress: status.message.isEmpty ? status.name : status.message,
                        isConnected: status.isConnected,
                        status: status.status,
                        batteryVoltage: 0, batteryCurrent: 0, batteryTemperature: 0, batteryPercentage: -1,
                        buttons: 0, leftButtons: 0, rightButtons: 0,
                        leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0,
                        gyroX: 0, gyroY: 0, gyroZ: 0,
                        accelX: 0, accelY: 0, accelZ: 0,
                        mouseX: 0, mouseY: 0, mouseDistance: 0,
                        triggerL: 0, triggerR: 0,
                        packetCount: 0, mouseMode: .normal,
                        mouseSource: .auto, mouseActiveSide: "right",
                        rssi: 0
                    )
                )
                updated.sort { $0.id < $1.id }
                changed = true
            }
        }

        for (_, snapshot) in states {
            var merged = snapshot

            // Flicker guard: if the user just changed mouseMode or
            // mouseSource, stale state packets still carry the old daemon
            // value. Override the snapshot's value with the pending choice
            // until the daemon confirms it or the window expires.
            let now = Date()
            if let pending = pendingMouseMode,
               let deadline = pendingMouseModeDeadline, now < deadline {
                if merged.mouseMode == pending {
                    // Daemon just confirmed the change — release guard.
                    pendingMouseMode = nil
                    pendingMouseModeDeadline = nil
                } else {
                    merged.mouseMode = pending
                }
            } else if pendingMouseModeDeadline != nil {
                pendingMouseMode = nil
                pendingMouseModeDeadline = nil
            }
            if let pending = pendingMouseSource,
               let deadline = pendingMouseSourceDeadline, now < deadline {
                if merged.mouseSource == pending {
                    pendingMouseSource = nil
                    pendingMouseSourceDeadline = nil
                } else {
                    merged.mouseSource = pending
                }
            } else if pendingMouseSourceDeadline != nil {
                pendingMouseSource = nil
                pendingMouseSourceDeadline = nil
            }

            if let index = updated.firstIndex(where: { $0.id == merged.id }) {
                if updated[index].status == "ready" { merged.status = "ready" }
                updated[index] = merged
            } else {
                updated.append(merged)
                updated.sort { $0.id < $1.id }
            }
            changed = true
        }

        if changed {
            controllers = updated
            stateRevision &+= 1
        }
    }

    // MARK: - Misc

    func toggleMouseMode() {
        // The mouse emitter lives in the daemon, so the authoritative mouse
        // mode is whatever g_mouseEmitter.currentMode says. Pick the next
        // value based on our last-seen mirror and forward the target to the
        // daemon via the control file. The daemon echoes "mouseMode" events
        // back in telemetry, which will update the ControllerState mirror
        // through the normal state-parse pipeline on the next packet.
        let currentRaw = controllers.first?.mouseMode.rawValue ?? 0
        let nextRaw = (currentRaw + 1) % 4
        sendControlCommand(["cmd": "setMouseMode", "value": nextRaw])

        // Optimistic UI update so the picker / toggle button shows the new
        // state immediately; the next state event from the daemon will
        // correct it if the command was rejected.
        let nextMode = MouseMode(rawValue: nextRaw) ?? .off
        pendingMouseMode = nextMode
        pendingMouseModeDeadline = Date().addingTimeInterval(pendingEchoWindow)
        if !controllers.isEmpty {
            var updated = controllers
            updated[0].mouseMode = nextMode
            controllers = updated
            stateRevision &+= 1
        }
    }

    func setMouseMode(_ mode: MouseMode) {
        sendControlCommand(["cmd": "setMouseMode", "value": mode.rawValue])
        // Hold the pending value across stale state echoes so the Picker
        // doesn't flash back to the previous selection while the daemon
        // catches up. See pendingEchoWindow for the window length.
        pendingMouseMode = mode
        pendingMouseModeDeadline = Date().addingTimeInterval(pendingEchoWindow)
        if !controllers.isEmpty {
            var updated = controllers
            for index in updated.indices {
                updated[index].mouseMode = mode
            }
            controllers = updated
            stateRevision &+= 1
        }
    }

    func setMouseSource(_ source: MouseSource) {
        sendControlCommand(["cmd": "setMouseSource", "value": source.rawValue])
        pendingMouseSource = source
        pendingMouseSourceDeadline = Date().addingTimeInterval(pendingEchoWindow)
        if !controllers.isEmpty {
            var updated = controllers
            for index in updated.indices {
                updated[index].mouseSource = source
            }
            controllers = updated
            stateRevision &+= 1
        }
    }

    func setSDLOnlyMode(_ enabled: Bool) {
        sendControlCommand(["cmd": "setSDLOnlyMode", "value": enabled ? 1 : 0])
    }

    func setFindJoyCon(left: Bool, right: Bool) {
        findingLeftJoyCon = left
        findingRightJoyCon = right
        sendControlCommand([
            "cmd": "setFindJoyCon",
            "left": left ? 1 : 0,
            "right": right ? 1 : 0
        ])
    }

    func setRailBindings(_ bindings: [String: String]) {
        sendControlCommand(["cmd": "setRailBindings", "bindings": bindings])
    }

    private func sendStoredRailBindings() {
        let defaults = UserDefaults.standard
        setRailBindings([
            "leftSL": defaults.string(forKey: "railBinding.leftSL") ?? "none",
            "leftSR": defaults.string(forKey: "railBinding.leftSR") ?? "none",
            "rightSL": defaults.string(forKey: "railBinding.rightSL") ?? "none",
            "rightSR": defaults.string(forKey: "railBinding.rightSR") ?? "none"
        ])
    }

    private func applyFindStatus(_ detail: String) {
        let pairs = detail.split(separator: " ").reduce(into: [String: String]()) { result, token in
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return }
            result[String(parts[0])] = String(parts[1])
        }
        if let left = pairs["left"] {
            findingLeftJoyCon = left == "1"
        }
        if let right = pairs["right"] {
            findingRightJoyCon = right == "1"
        }
    }

    /// Append one JSON command line to the control file. The daemon polls
    /// the file at 10 Hz and applies each complete newline-terminated
    /// object exactly once, so ordering is preserved and partial writes
    /// aren't picked up until the newline is flushed.
    private func sendControlCommand(_ payload: [String: Any]) {
        guard let daemonControlPath else {
            TelemetryStore.shared.append("[control] daemon not running; dropping command")
            return
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")
        guard let bytes = line.data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: daemonControlPath)
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            try handle.close()
        } catch {
            TelemetryStore.shared.append("[control] write failed: \(error.localizedDescription)")
        }
    }

    func scanNFC() {
        TelemetryStore.shared.append("NFC scan requested on the right Joy-Con.")
        sendControlCommand(["cmd": "scanNFC"])
    }

    func stopNFC() {
        TelemetryStore.shared.append("NFC scan stopped.")
        sendControlCommand(["cmd": "stopNFC"])
    }

    var telemetryLogPath: String {
        TelemetryStore.shared.telemetryLogPath
    }

    func revealTelemetryLog() {
        TelemetryStore.shared.revealLog()
    }

    func copyTelemetryToClipboard() {
        TelemetryStore.shared.copyToClipboard()
    }

    func clearTelemetryView() {
        TelemetryStore.shared.clear()
    }

    // Expose counters for diagnostic overlay.
    func ingestDiagnostics() -> (leftKept: UInt64, rightKept: UInt64, leftDropped: UInt64, rightDropped: UInt64) {
        ingestQueue.sync {
            (ingestPacketCountLeft, ingestPacketCountRight, ingestPacketDropLeft, ingestPacketDropRight)
        }
    }

    func installAndLoadDriver() {
        // Apple requires the dext filename, CFBundleExecutable, and
        // CFBundleIdentifier to all agree. Our build pipeline now names the
        // bundle after the identifier (local.joycon2mac.driver.dext). We
        // still fall back to the old "VirtualJoyConDriver.dext" path for
        // .apps produced by pre-rename builds that someone might have
        // hanging around, but new builds will resolve the first URL.
        let extensionsDir = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Library")
            .appendingPathComponent("SystemExtensions")

        let candidates = [
            extensionsDir.appendingPathComponent("local.joycon2mac.driver.dext"),
            extensionsDir.appendingPathComponent("VirtualJoyConDriver.dext")
        ]

        guard let embeddedDextURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            let msg = "Driver extension is missing from Contents/Library/SystemExtensions."
            driverInstallStatus = msg
            TelemetryStore.shared.updateDriverStatus(msg)
            TelemetryStore.shared.append(msg)
            return
        }

        let initial = "Submitting driver activation request..."
        driverInstallStatus = initial
        TelemetryStore.shared.updateDriverStatus(initial)
        TelemetryStore.shared.append("Activating DriverKit extension from \(embeddedDextURL.path)")

        DriverExtensionInstaller.shared.activate { [weak self] status, shouldRestartDaemon in
            DispatchQueue.main.async {
                self?.driverInstallStatus = status
                TelemetryStore.shared.updateDriverStatus(status)
                TelemetryStore.shared.append("[driver] \(status)")
                if shouldRestartDaemon {
                    self?.restartDaemon()
                }
            }
        }
    }

    private func markControllersDisconnected(status: String) {
        var updated = controllers
        for index in updated.indices {
            updated[index].isConnected = false
            updated[index].status = status
        }
        controllers = updated
        stateRevision &+= 1
    }

    private func handleDaemonTerminated() {
        daemonApplication = nil
        daemonProcess = nil
        outputPipe = nil
        stopLogPolling()
        isDaemonRunning = false
        TelemetryStore.shared.append("[daemon] helper process terminated")
        if shouldRestartAfterTermination {
            shouldRestartAfterTermination = false
            startDaemon()
        } else {
            markControllersDisconnected(status: "daemonStopped")
        }
    }

    private func statusRank(_ status: String) -> Int {
        switch status {
        case "daemonStopped": return -1
        case "scanning": return 0
        case "queued": return 1
        case "connecting": return 2
        case "bleConnected": return 3
        case "servicesReady": return 4
        case "initializing": return 5
        case "commandTimeout", "writeFailed": return 6
        case "streaming": return 7
        case "ready": return 8
        case "connectFailed", "disconnected": return 100
        default: return 0
        }
    }

    private func shouldReplaceStatus(current: String, incoming: String) -> Bool {
        if ["connectFailed", "disconnected", "daemonStopped"].contains(incoming) {
            return true
        }
        if current == "daemonStopped" {
            return true
        }
        return statusRank(incoming) >= statusRank(current)
    }

    private func stringValue(_ value: Any?, default defaultValue: String) -> String {
        value as? String ?? defaultValue
    }

    private func intValue(_ value: Any?, default defaultValue: Int = 0) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? defaultValue }
        return defaultValue
    }

    private func uint32Value(_ value: Any?) -> UInt32 {
        UInt32(max(0, intValue(value)))
    }

    private func uint8Value(_ value: Any?) -> UInt8 {
        UInt8(max(0, min(255, intValue(value))))
    }

    private func int16Value(_ value: Any?) -> Int16 {
        Int16(max(Int(Int16.min), min(Int(Int16.max), intValue(value))))
    }

    private func doubleValue(_ value: Any?, default defaultValue: Double = 0) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) ?? defaultValue }
        return defaultValue
    }

    private func dataFromHexString(_ hex: String) -> Data {
        var bytes = Data()
        var highNibble: UInt8?

        for character in hex {
            guard let nibble = character.hexDigitValue else { continue }
            let value = UInt8(nibble)
            if let high = highNibble {
                bytes.append((high << 4) | value)
                highNibble = nil
            } else {
                highNibble = value
            }
        }

        return bytes
    }
}
