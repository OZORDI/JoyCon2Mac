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
    var controllerTemperature: Double
    var batteryPercentage: Double
    var batteryChargeStatus: UInt8
    var batteryVoltageValid: Bool
    var batteryCurrentValid: Bool
    var controllerTemperatureValid: Bool
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
    var pointerMethod: PointerMethod
    var gyroMouseSource: GyroMouseSource
    var gyroOutputMode: GyroOutputMode
    var gyroStickFullRate: Double
    var gyroStickMinimumOutput: Double
    var gyroStickResponseCurve: Double
    var gyroAimingEnabled: Bool
    var gyroOutputActive: Bool
    var gyroCalibrating: Bool
    var gyroActiveSource: String
    var gyroActivationMode: GyroActivationMode
    var gyroActivationSlot1: GyroActivationBinding
    var gyroActivationSlot2: GyroActivationBinding
    var gyroActivationSlot3: GyroActivationBinding
    var rssi: Int
}

/// High-rate controller snapshots live outside `DaemonBridge` so publishing a
/// stick or IMU sample does not invalidate every view that observes daemon
/// lifecycle, settings, or NFC state.
final class ControllerStore: ObservableObject {
    @Published fileprivate(set) var controllers: [ControllerState] = []
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

enum PointerMethod: Int {
    case optical = 0
    case gyroAiming = 1
}

enum GyroMouseSource: Int {
    case fused = 0
    case left = 1
    case right = 2
}

enum GyroOutputMode: Int {
    case mouse = 0
    case rightStick = 1
}

enum GyroActivationMode: Int, CaseIterable, Identifiable {
    case continuous = 0
    case hold = 1
    case toggle = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .continuous: return "Continuous"
        case .hold: return "Hold"
        case .toggle: return "Toggle"
        }
    }
}

enum GyroActivationBinding: String, CaseIterable, Identifiable {
    case none
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case l, zl, minus, leftStick, capture, leftSL, leftSR
    case a, b, x, y, r, zr, plus, rightStick, home, chat, rightSL, rightSR

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .dpadUp: return "D-Pad Up"
        case .dpadDown: return "D-Pad Down"
        case .dpadLeft: return "D-Pad Left"
        case .dpadRight: return "D-Pad Right"
        case .l: return "L / L1"
        case .zl: return "ZL / L2"
        case .capture: return "Capture"
        case .minus: return "Minus"
        case .leftStick: return "Left Stick / L3"
        case .leftSL: return "Left SL"
        case .leftSR: return "Left SR"
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .r: return "R / R1"
        case .zr: return "ZR / R2"
        case .plus: return "Plus"
        case .rightStick: return "Right Stick / R3"
        case .home: return "Home"
        case .chat: return "Chat"
        case .rightSL: return "Right SL"
        case .rightSR: return "Right SR"
        }
    }
}

struct NFCDecodedRecord: Identifiable, Equatable {
    var id: String { "\(label)\u{1f}\(value)" }
    var label: String
    var value: String
}

struct NFCTag: Identifiable, Equatable {
    var id: String { uid }
    var uid: String
    var type: String
    var data: Data
    var firstSeen: Date
    var lastSeen: Date
    var scanCount: Int
    var decodedRecords: [NFCDecodedRecord]
    var readStatus: Int
    var readMessage: String
}

enum NFCDecoder {
    private static let uriPrefixes = [
        "", "http://www.", "https://www.", "http://", "https://",
        "tel:", "mailto:", "ftp://anonymous:anonymous@", "ftp://ftp.",
        "ftps://", "sftp://", "smb://", "nfs://", "ftp://",
        "dav://", "news:", "telnet://", "imap:", "rtsp://", "urn:",
        "pop:", "sip:", "sips:", "tftp:", "btspp://", "btl2cap://",
        "btgoep://", "tcpobex://", "irdaobex://", "file://",
        "urn:epc:id:", "urn:epc:tag:", "urn:epc:pat:",
        "urn:epc:raw:", "urn:epc:", "urn:nfc:"
    ]

    static func decode(_ data: Data) -> [NFCDecodedRecord] {
        var records: [NFCDecodedRecord] = []

        records.append(contentsOf: asciiURLs(in: data).map {
            NFCDecodedRecord(label: "URL", value: $0)
        })

        records.append(contentsOf: decodeNDEFContainers(in: data))

        var seen = Set<String>()
        return records.filter { record in
            let key = "\(record.label)\u{1f}\(record.value)"
            return seen.insert(key).inserted
        }
    }

    private static func decodeNDEFContainers(in data: Data) -> [NFCDecodedRecord] {
        let bytes = Array(data)
        var records: [NFCDecodedRecord] = []

        for offset in bytes.indices {
            records.append(contentsOf: decodeTLV(from: bytes, offset: offset))
            records.append(contentsOf: decodeNDEFRecords(Array(bytes[offset...])))
        }
        return records
    }

    private static func decodeTLV(from bytes: [UInt8], offset: Int) -> [NFCDecodedRecord] {
        var index = offset
        var records: [NFCDecodedRecord] = []

        while index < bytes.count {
            let type = bytes[index]
            index += 1

            if type == 0x00 { continue }
            if type == 0xFE { break }

            guard index < bytes.count else { break }
            var length = Int(bytes[index])
            index += 1
            if length == 0xFF {
                guard index + 1 < bytes.count else { break }
                length = (Int(bytes[index]) << 8) | Int(bytes[index + 1])
                index += 2
            }
            guard length >= 0, index + length <= bytes.count else { break }

            if type == 0x03 {
                records.append(contentsOf: decodeNDEFRecords(Array(bytes[index..<index + length])))
            }
            index += length
        }
        return records
    }

    private static func decodeNDEFRecords(_ bytes: [UInt8]) -> [NFCDecodedRecord] {
        var index = 0
        var decoded: [NFCDecodedRecord] = []

        while index < bytes.count {
            let header = bytes[index]
            index += 1

            let messageBegin = (header & 0x80) != 0
            let messageEnd = (header & 0x40) != 0
            let shortRecord = (header & 0x10) != 0
            let hasID = (header & 0x08) != 0
            let tnf = header & 0x07

            if !messageBegin || tnf == 0x00 {
                break
            }

            guard index < bytes.count else { break }
            let typeLength = Int(bytes[index])
            index += 1

            let payloadLength: Int
            if shortRecord {
                guard index < bytes.count else { break }
                payloadLength = Int(bytes[index])
                index += 1
            } else {
                guard index + 3 < bytes.count else { break }
                payloadLength = (Int(bytes[index]) << 24) |
                                (Int(bytes[index + 1]) << 16) |
                                (Int(bytes[index + 2]) << 8) |
                                Int(bytes[index + 3])
                index += 4
            }

            let idLength: Int
            if hasID {
                guard index < bytes.count else { break }
                idLength = Int(bytes[index])
                index += 1
            } else {
                idLength = 0
            }

            guard typeLength >= 0,
                  payloadLength >= 0,
                  idLength >= 0,
                  index + typeLength + idLength + payloadLength <= bytes.count else { break }

            let typeData = Array(bytes[index..<index + typeLength])
            index += typeLength + idLength
            let payload = Array(bytes[index..<index + payloadLength])
            index += payloadLength

            decoded.append(contentsOf: decodeRecord(tnf: tnf, type: typeData, payload: payload))
            if messageEnd { break }
        }
        return decoded
    }

    private static func decodeRecord(tnf: UInt8, type: [UInt8], payload: [UInt8]) -> [NFCDecodedRecord] {
        guard !payload.isEmpty else { return [] }

        if tnf == 0x01, type == [0x55] {
            let prefixIndex = Int(payload[0])
            let prefix = prefixIndex < uriPrefixes.count ? uriPrefixes[prefixIndex] : ""
            let suffix = String(bytes: payload.dropFirst(), encoding: .utf8) ?? ""
            guard !suffix.isEmpty else { return [] }
            return [NFCDecodedRecord(label: "URL", value: prefix + suffix)]
        }

        if tnf == 0x01, type == [0x54] {
            let status = payload[0]
            let isUTF16 = (status & 0x80) != 0
            let languageLength = Int(status & 0x3F)
            guard payload.count > 1 + languageLength else { return [] }
            let textBytes = payload.dropFirst(1 + languageLength)
            let encoding: String.Encoding = isUTF16 ? .utf16BigEndian : .utf8
            if let text = String(bytes: textBytes, encoding: encoding), !text.isEmpty {
                return [NFCDecodedRecord(label: "Text", value: text)]
            }
        }

        if tnf == 0x01, type == [0x53, 0x70] {
            return decodeNDEFRecords(payload)
        }

        if tnf == 0x03, let uri = String(bytes: payload, encoding: .utf8), !uri.isEmpty {
            return [NFCDecodedRecord(label: "URI", value: uri)]
        }

        return []
    }

    private static func asciiURLs(in data: Data) -> [String] {
        guard let raw = String(data: data, encoding: .utf8) else { return [] }
        let prefixes = ["https://", "http://", "www."]
        var urls: [String] = []

        for prefix in prefixes {
            var searchStart = raw.startIndex
            while let range = raw.range(of: prefix, range: searchStart..<raw.endIndex) {
                var end = range.lowerBound
                while end < raw.endIndex {
                    let char = raw[end]
                    if char.isWhitespace || char.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                        break
                    }
                    end = raw.index(after: end)
                }
                urls.append(String(raw[range.lowerBound..<end]))
                searchStart = end
            }
        }
        return urls
    }

    static func printableStrings(in data: Data) -> [NFCDecodedRecord] {
        let bytes = Array(data)
        var strings: [String] = []
        var current: [UInt8] = []

        func flush() {
            guard current.count >= 4,
                  let value = String(bytes: current, encoding: .utf8) else {
                current.removeAll(keepingCapacity: true)
                return
            }
            strings.append(value)
            current.removeAll(keepingCapacity: true)
        }

        for byte in bytes {
            if (0x20...0x7E).contains(byte) {
                current.append(byte)
            } else {
                flush()
            }
        }
        flush()

        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }.map {
            NFCDecodedRecord(label: "Text fragment", value: $0)
        }
    }
}

// Design notes (frozen-UI postmortem)
//
// The UI was freezing because an append-only JSONL file was polled every 8 ms
// while controller snapshots were published at up to 120 Hz. Every view that
// observed DaemonBridge was consequently invalidated by controller motion.
//
// Throttling step 3 in isolation does NOT help: steps 1-2 still thrash the
// main run loop. SwiftUI cannot repaint. Apple's Combine / Concurrency docs
// (https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app)
// explicitly recommend running data ingest on a background queue and
// publishing to main via a throttled pipeline.
//
// The transport is now a named pipe: FileHandle wakes only when bytes arrive,
// and consumed state never accumulates on disk. JSON parsing remains on a
// serial background queue, state is coalesced at 30 Hz, and high-rate
// ControllerState publication is isolated in ControllerStore. Telemetry text
// remains isolated in TelemetryStore.
class DaemonBridge: ObservableObject {
    static let shared = DaemonBridge()

    let controllerStore = ControllerStore()
    var controllers: [ControllerState] {
        get { controllerStore.controllers }
        set {
            controllerStore.controllers = newValue
            let count = newValue.lazy.filter(\.isConnected).count
            if connectedControllerCount != count {
                connectedControllerCount = count
            }
        }
    }

    @Published private(set) var connectedControllerCount = 0
    @Published var nfcTags: [NFCTag] = []
    @Published var isDaemonRunning = false
    // Kept for source-compat with older views. Never mutated from the
    // packet firehose now; only on driver-install result.
    @Published var driverInstallStatus: String = ""
    @Published var findingLeftJoyCon = false
    @Published var findingRightJoyCon = false

    // Background queue that owns stream parsing and throttling.
    // Nothing on this queue touches @Published state directly.
    private let ingestQueue = DispatchQueue(label: "local.joycon2mac.ingest", qos: .userInitiated)

    private var daemonProcess: Process?
    private var daemonApplication: NSRunningApplication?
    private var outputPipe: Pipe?
    private var pendingOutput = ""
    // Per-controller rate limiter (accessed only on ingestQueue).
    private var lastIngestTime: [String: Date] = [:]
    private let controllerUpdateInterval: TimeInterval = 1.0 / 30.0
    private var shouldRestartAfterTermination = false
    private var daemonStreamHandle: FileHandle?
    private var daemonStreamPath: URL?
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
        _ = try? traceFileHandle?.seekToEnd()
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
                self.stopDaemonStream()
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
                self?.sendStoredMouseSettings()
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
            // State is a live IPC stream, not a durable log. Replacing the old
            // append-only daemon.jsonl with a FIFO prevents controller frames
            // from accumulating gigabytes on disk and lets FileHandle wake us
            // only when the daemon has data.
            let streamPath = supportDir.appendingPathComponent("daemon.jsonl")
            try prepareDaemonStream(at: streamPath)
            // Control-channel file. GUI writes one JSON command per line,
            // daemon polls. Truncate on start so stale commands from a
            // previous session don't get re-applied.
            let controlPath = supportDir.appendingPathComponent("control.jsonl")
            try Data().write(to: controlPath, options: .atomic)
            daemonControlPath = controlPath
            // Detailed input tracing is intentionally opt-in. Stick and IMU
            // noise make change-triggered traces surprisingly write-heavy.
            let inputTraceEnabled = UserDefaults.standard.bool(forKey: "diagnostics.inputTrace")
            if inputTraceEnabled {
                let tracePath = supportDir.appendingPathComponent("input-trace.log")
                try? Data().write(to: tracePath, options: .atomic)
                openTraceFile(at: tracePath)
            }
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
            var arguments = [
                "--json",
                "--json-file", streamPath.path,
                "--control-file", controlPath.path
            ]
            if inputTraceEnabled {
                arguments.append("--debug-input")
            }
            if UserDefaults.standard.bool(forKey: "sdlOnlyMode") {
                arguments.append("--sdl-only")
            }
            configuration.arguments = arguments

            isDaemonRunning = true

            NSWorkspace.shared.openApplication(at: helperApp, configuration: configuration) { [weak self] app, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if generation != self.daemonGeneration { return }
                    if let error {
                        TelemetryStore.shared.append("Failed to start helper daemon: \(error)")
                        self.isDaemonRunning = false
                        self.stopDaemonStream()
                        self.markControllersDisconnected(status: "daemonStopped")
                        return
                    }
                    self.daemonApplication = app
                    // Observe termination so we can flip the running flag if
                    // the helper dies unexpectedly.
                    if let app {
                        self.observeDaemonTermination(app: app, generation: generation)
                    }
                }
            }
            return true
        } catch {
            stopDaemonStream()
            TelemetryStore.shared.append("Failed to prepare daemon stream: \(error)")
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
            stopDaemonStream()
            markControllersDisconnected(status: "daemonStopped")
            return
        }

        guard let process = daemonProcess else {
            outputPipe = nil
            stopDaemonStream()
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

    // MARK: - Daemon event stream

    private func prepareDaemonStream(at path: URL) throws {
        stopDaemonStream()

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
        }

        guard Darwin.mkfifo(path.path, mode_t(0o600)) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Could not create daemon event pipe"]
            )
        }

        // O_RDWR keeps the FIFO alive before LaunchServices starts the helper
        // and prevents a transient EOF between daemon restarts. O_NONBLOCK
        // guarantees setup cannot wait on a process that has not launched yet.
        let descriptor = Darwin.open(path.path, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else {
            let openError = errno
            try? fileManager.removeItem(at: path)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(openError),
                userInfo: [NSLocalizedDescriptionKey: "Could not open daemon event pipe"]
            )
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        daemonStreamPath = path
        daemonStreamHandle = handle
        handle.readabilityHandler = { [weak self] readableHandle in
            let data = readableHandle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else {
                return
            }
            self?.ingestQueue.async { [weak self] in
                self?.parseDaemonOutputOnIngestQueue(output)
            }
        }
    }

    private func stopDaemonStream() {
        let handle = daemonStreamHandle
        daemonStreamHandle = nil
        handle?.readabilityHandler = nil
        try? handle?.close()

        let traceHandle = traceFileHandle
        traceFileHandle = nil
        try? traceHandle?.close()
        lastTraceRightX = .min
        lastTraceRightY = .min
        lastTraceLeftX = .min
        lastTraceLeftY = .min

        if let path = daemonStreamPath {
            try? FileManager.default.removeItem(at: path)
        }
        daemonStreamPath = nil

        ingestQueue.async { [weak self] in
            self?.pendingOutput = ""
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
                        self?.sendStoredMouseSettings()
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
            if traceFileHandle != nil, snapshot.side == "right" {
                if snapshot.rightStickX != lastTraceRightX || snapshot.rightStickY != lastTraceRightY {
                    writeTrace(String(
                        format: "[RS-UI] RS=(%6d,%6d) LS=(%6d,%6d) btn=0x%06x",
                        snapshot.rightStickX, snapshot.rightStickY,
                        snapshot.leftStickX, snapshot.leftStickY,
                        snapshot.buttons))
                    lastTraceRightX = snapshot.rightStickX
                    lastTraceRightY = snapshot.rightStickY
                }
            } else if traceFileHandle != nil {
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
            let data = dataFromHexString(payloadHex)
            let type = object["type"] as? String ?? "Vendor"
            let readStatus = intValue(object["status"])
            let readMessage: String
            if readStatus == 0 {
                readMessage = "Tag detected; reading"
            } else if readStatus == 1 {
                readMessage = "Read complete"
            } else if data.count >= 2, data[data.startIndex] == 0x07, data[data.startIndex + 1] == 0x48 {
                readMessage = "Detected, but not in the Amiibo format"
            } else {
                readMessage = "Read failed"
            }
            let timestamp = Date()
            let decodedRecords = NFCDecoder.decode(data) + NFCDecoder.printableStrings(in: data)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let existingIndex = self.nfcTags.firstIndex(where: { $0.uid == uid }) {
                    var tag = self.nfcTags.remove(at: existingIndex)
                    tag.type = type
                    tag.lastSeen = timestamp
                    tag.readStatus = readStatus
                    tag.readMessage = readMessage
                    if readStatus == 0 {
                        tag.scanCount += 1
                    } else {
                        tag.data = data
                        tag.decodedRecords = decodedRecords
                    }
                    self.nfcTags.insert(tag, at: 0)
                } else {
                    let tag = NFCTag(
                        uid: uid,
                        type: type,
                        data: data,
                        firstSeen: timestamp,
                        lastSeen: timestamp,
                        scanCount: 1,
                        decodedRecords: decodedRecords,
                        readStatus: readStatus,
                        readMessage: readMessage
                    )
                    self.nfcTags.insert(tag, at: 0)
                }
            }
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
        let batteryVoltage = doubleValue(object["batteryVoltage"])
        let batteryCurrent = doubleValue(object["batteryCurrent"])
        let controllerTemperature = doubleValue(
            object["controllerTemperature"] ?? object["batteryTemperature"]
        )
        let batteryVoltageValid =
            (object["batteryVoltageValid"] as? NSNumber)?.boolValue ?? (batteryVoltage > 0)
        let batteryCurrentValid =
            (object["batteryCurrentValid"] as? NSNumber)?.boolValue ?? (batteryCurrent > 0)
        let controllerTemperatureValid =
            (object["controllerTemperatureValid"] as? NSNumber)?.boolValue
                ?? (object["controllerTemperature"] != nil || object["batteryTemperature"] != nil)
        return ControllerState(
            id: normalizedSide,
            side: normalizedSide,
            name: normalizedSide == "right" ? "Joy-Con R" : "Joy-Con L",
            macAddress: normalizedSide == "right" ? "Right BLE peripheral" : "Left BLE peripheral",
            isConnected: true,
            status: "streaming",
            batteryVoltage: batteryVoltage,
            batteryCurrent: batteryCurrent,
            controllerTemperature: controllerTemperature,
            batteryPercentage: doubleValue(object["batteryPercentage"], default: -1),
            batteryChargeStatus: uint8Value(object["batteryChargeStatus"]),
            batteryVoltageValid: batteryVoltageValid,
            batteryCurrentValid: batteryCurrentValid,
            controllerTemperatureValid: controllerTemperatureValid,
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
            pointerMethod: PointerMethod(rawValue: intValue(object["pointerMethod"])) ?? .optical,
            gyroMouseSource: GyroMouseSource(rawValue: intValue(object["gyroMouseSource"])) ?? .fused,
            gyroOutputMode: GyroOutputMode(rawValue: intValue(object["gyroOutputMode"])) ?? .mouse,
            gyroStickFullRate: doubleValue(object["gyroStickFullRate"], default: 180),
            gyroStickMinimumOutput: doubleValue(object["gyroStickMinimumOutput"], default: 0.12),
            gyroStickResponseCurve: doubleValue(object["gyroStickResponseCurve"], default: 1),
            gyroAimingEnabled: (object["gyroAimingEnabled"] as? NSNumber)?.boolValue ?? false,
            gyroOutputActive: (object["gyroOutputActive"] as? NSNumber)?.boolValue ?? false,
            gyroCalibrating: (object["gyroCalibrating"] as? NSNumber)?.boolValue ?? true,
            gyroActiveSource: stringValue(object["gyroActiveSource"], default: "none"),
            gyroActivationMode: GyroActivationMode(rawValue: intValue(object["gyroActivationMode"])) ?? .hold,
            gyroActivationSlot1: GyroActivationBinding(rawValue: stringValue(object["gyroActivationSlot1"], default: "zl")) ?? .zl,
            gyroActivationSlot2: GyroActivationBinding(rawValue: stringValue(object["gyroActivationSlot2"], default: "none")) ?? .none,
            gyroActivationSlot3: GyroActivationBinding(rawValue: stringValue(object["gyroActivationSlot3"], default: "none")) ?? .none,
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
    private let mainApplyInterval: TimeInterval = 1.0 / 30.0

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
    private var pendingPointerMethod: PointerMethod?
    private var pendingPointerMethodDeadline: Date?
    private var pendingGyroMouseSource: GyroMouseSource?
    private var pendingGyroMouseSourceDeadline: Date?
    private var pendingGyroAimingEnabled: Bool?
    private var pendingGyroAimingEnabledDeadline: Date?
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
                        batteryVoltage: 0, batteryCurrent: 0, controllerTemperature: 0,
                        batteryPercentage: -1, batteryChargeStatus: 0,
                        batteryVoltageValid: false, batteryCurrentValid: false,
                        controllerTemperatureValid: false,
                        buttons: 0, leftButtons: 0, rightButtons: 0,
                        leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0,
                        gyroX: 0, gyroY: 0, gyroZ: 0,
                        accelX: 0, accelY: 0, accelZ: 0,
                        mouseX: 0, mouseY: 0, mouseDistance: 0,
                        triggerL: 0, triggerR: 0,
                        packetCount: 0, mouseMode: .normal,
                        mouseSource: .auto, mouseActiveSide: "right",
                        pointerMethod: .optical, gyroMouseSource: .fused,
                        gyroOutputMode: .mouse,
                        gyroStickFullRate: 180,
                        gyroStickMinimumOutput: 0.12,
                        gyroStickResponseCurve: 1,
                        gyroAimingEnabled: false, gyroOutputActive: false,
                        gyroCalibrating: true,
                        gyroActiveSource: "none",
                        gyroActivationMode: .hold,
                        gyroActivationSlot1: .zl,
                        gyroActivationSlot2: .none,
                        gyroActivationSlot3: .none,
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
            if let pending = pendingPointerMethod,
               let deadline = pendingPointerMethodDeadline, now < deadline {
                if merged.pointerMethod == pending {
                    pendingPointerMethod = nil
                    pendingPointerMethodDeadline = nil
                } else {
                    merged.pointerMethod = pending
                }
            } else if pendingPointerMethodDeadline != nil {
                pendingPointerMethod = nil
                pendingPointerMethodDeadline = nil
            }
            if let pending = pendingGyroMouseSource,
               let deadline = pendingGyroMouseSourceDeadline, now < deadline {
                if merged.gyroMouseSource == pending {
                    pendingGyroMouseSource = nil
                    pendingGyroMouseSourceDeadline = nil
                } else {
                    merged.gyroMouseSource = pending
                }
            } else if pendingGyroMouseSourceDeadline != nil {
                pendingGyroMouseSource = nil
                pendingGyroMouseSourceDeadline = nil
            }
            if let pending = pendingGyroAimingEnabled,
               let deadline = pendingGyroAimingEnabledDeadline, now < deadline {
                if merged.gyroAimingEnabled == pending {
                    pendingGyroAimingEnabled = nil
                    pendingGyroAimingEnabledDeadline = nil
                } else {
                    merged.gyroAimingEnabled = pending
                }
            } else if pendingGyroAimingEnabledDeadline != nil {
                pendingGyroAimingEnabled = nil
                pendingGyroAimingEnabledDeadline = nil
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
        }
    }

    func setMouseMode(_ mode: MouseMode) {
        sendControlCommand(["cmd": "setMouseMode", "value": mode.rawValue])
        UserDefaults.standard.set(mode.rawValue, forKey: "mouse.mode")
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
        }
    }

    func setMouseSource(_ source: MouseSource) {
        sendControlCommand(["cmd": "setMouseSource", "value": source.rawValue])
        UserDefaults.standard.set(source.rawValue, forKey: "mouse.opticalSource")
        pendingMouseSource = source
        pendingMouseSourceDeadline = Date().addingTimeInterval(pendingEchoWindow)
        if !controllers.isEmpty {
            var updated = controllers
            for index in updated.indices {
                updated[index].mouseSource = source
            }
            controllers = updated
        }
    }

    func setPointerMethod(_ method: PointerMethod) {
        let shouldEnableGyro = method == .gyroAiming
        if shouldEnableGyro, controllers.first?.mouseMode == .off {
            sendControlCommand(["cmd": "setMouseMode", "value": MouseMode.normal.rawValue])
            UserDefaults.standard.set(MouseMode.normal.rawValue, forKey: "mouse.mode")
            pendingMouseMode = .normal
            pendingMouseModeDeadline = Date().addingTimeInterval(pendingEchoWindow)
        }
        sendControlCommand(["cmd": "setPointerMethod", "value": method.rawValue])
        sendControlCommand(["cmd": "setGyroAimingEnabled", "value": shouldEnableGyro ? 1 : 0])
        UserDefaults.standard.set(method.rawValue, forKey: "mouse.pointerMethod")
        pendingPointerMethod = method
        pendingPointerMethodDeadline = Date().addingTimeInterval(pendingEchoWindow)
        pendingGyroAimingEnabled = shouldEnableGyro
        pendingGyroAimingEnabledDeadline = Date().addingTimeInterval(pendingEchoWindow)
        if !controllers.isEmpty {
            var updated = controllers
            for index in updated.indices {
                if shouldEnableGyro, updated[index].mouseMode == .off {
                    updated[index].mouseMode = .normal
                }
                updated[index].pointerMethod = method
                updated[index].gyroAimingEnabled = shouldEnableGyro
            }
            controllers = updated
        }
    }

    func setGyroMouseSource(_ source: GyroMouseSource) {
        let shouldResume = controllers.first?.gyroAimingEnabled ?? false
        sendControlCommand(["cmd": "setGyroMouseSource", "value": source.rawValue])
        if shouldResume {
            sendControlCommand(["cmd": "setGyroAimingEnabled", "value": 1])
        }
        UserDefaults.standard.set(source.rawValue, forKey: "mouse.gyroSource")
        pendingGyroMouseSource = source
        pendingGyroMouseSourceDeadline = Date().addingTimeInterval(pendingEchoWindow)
        pendingGyroAimingEnabled = shouldResume
        pendingGyroAimingEnabledDeadline = Date().addingTimeInterval(pendingEchoWindow)
        if !controllers.isEmpty {
            var updated = controllers
            for index in updated.indices {
                updated[index].gyroMouseSource = source
                updated[index].gyroAimingEnabled = shouldResume
            }
            controllers = updated
        }
    }

    func setGyroOutputMode(_ mode: GyroOutputMode) {
        sendControlCommand(["cmd": "setGyroOutputMode", "value": mode.rawValue])
        UserDefaults.standard.set(mode.rawValue, forKey: "mouse.gyroOutputMode")
        if !controllers.isEmpty {
            var updated = controllers
            for index in updated.indices { updated[index].gyroOutputMode = mode }
            controllers = updated
        }
    }

    func setGyroStickSettings(fullRate: Double,
                              minimumOutput: Double,
                              responseCurve: Double) {
        let appliedFullRate = min(max(fullRate, 30), 720)
        let appliedMinimumOutput = min(max(minimumOutput, 0), 0.5)
        let appliedResponseCurve = min(max(responseCurve, 0.25), 4)
        UserDefaults.standard.set(appliedFullRate, forKey: "mouse.gyroStickFullRate")
        UserDefaults.standard.set(appliedMinimumOutput, forKey: "mouse.gyroStickMinimumOutput")
        UserDefaults.standard.set(appliedResponseCurve, forKey: "mouse.gyroStickResponseCurve")
        sendControlCommand([
            "cmd": "setGyroStickSettings",
            "fullRate": appliedFullRate,
            "minimumOutput": appliedMinimumOutput,
            "responseCurve": appliedResponseCurve
        ])
        if !controllers.isEmpty {
            var updated = controllers
            for index in updated.indices {
                updated[index].gyroStickFullRate = appliedFullRate
                updated[index].gyroStickMinimumOutput = appliedMinimumOutput
                updated[index].gyroStickResponseCurve = appliedResponseCurve
            }
            controllers = updated
        }
    }

    func setGyroAimingEnabled(_ enabled: Bool) {
        sendControlCommand(["cmd": "setGyroAimingEnabled", "value": enabled ? 1 : 0])
        pendingGyroAimingEnabled = enabled
        pendingGyroAimingEnabledDeadline = Date().addingTimeInterval(pendingEchoWindow)
        if !controllers.isEmpty {
            var updated = controllers
            for index in updated.indices { updated[index].gyroAimingEnabled = enabled }
            controllers = updated
        }
    }

    func calibrateGyroPointer() {
        sendControlCommand(["cmd": "calibrateGyro"])
    }

    func setGyroActivation(mode: GyroActivationMode,
                           slot1: GyroActivationBinding,
                           slot2: GyroActivationBinding,
                           slot3: GyroActivationBinding) {
        UserDefaults.standard.set(mode.rawValue, forKey: "mouse.gyroActivationMode")
        UserDefaults.standard.set(slot1.rawValue, forKey: "mouse.gyroActivationSlot1")
        UserDefaults.standard.set(slot2.rawValue, forKey: "mouse.gyroActivationSlot2")
        UserDefaults.standard.set(slot3.rawValue, forKey: "mouse.gyroActivationSlot3")
        sendControlCommand([
            "cmd": "setGyroActivation",
            "mode": mode.rawValue,
            "slot1": slot1.rawValue,
            "slot2": slot2.rawValue,
            "slot3": slot3.rawValue
        ])
        if !controllers.isEmpty {
            var updated = controllers
            for index in updated.indices {
                updated[index].gyroActivationMode = mode
                updated[index].gyroActivationSlot1 = slot1
                updated[index].gyroActivationSlot2 = slot2
                updated[index].gyroActivationSlot3 = slot3
                updated[index].gyroOutputActive = false
            }
            controllers = updated
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

    private func sendStoredMouseSettings() {
        let defaults = UserDefaults.standard
        let mode = MouseMode(rawValue: defaults.object(forKey: "mouse.mode") as? Int ?? MouseMode.normal.rawValue) ?? .normal
        let opticalSource = MouseSource(rawValue: defaults.object(forKey: "mouse.opticalSource") as? Int ?? MouseSource.auto.rawValue) ?? .auto
        let method = PointerMethod(rawValue: defaults.object(forKey: "mouse.pointerMethod") as? Int ?? PointerMethod.optical.rawValue) ?? .optical
        let gyroSource = GyroMouseSource(rawValue: defaults.object(forKey: "mouse.gyroSource") as? Int ?? GyroMouseSource.fused.rawValue) ?? .fused
        let gyroOutput = GyroOutputMode(rawValue: defaults.object(forKey: "mouse.gyroOutputMode") as? Int ?? GyroOutputMode.mouse.rawValue) ?? .mouse
        let gyroStickFullRate = defaults.object(forKey: "mouse.gyroStickFullRate") as? Double ?? 180
        let gyroStickMinimumOutput = defaults.object(forKey: "mouse.gyroStickMinimumOutput") as? Double ?? 0.12
        let gyroStickResponseCurve = defaults.object(forKey: "mouse.gyroStickResponseCurve") as? Double ?? 1
        let activationMode = GyroActivationMode(rawValue: defaults.object(forKey: "mouse.gyroActivationMode") as? Int ?? GyroActivationMode.hold.rawValue) ?? .hold
        let activationSlot1 = GyroActivationBinding(rawValue: defaults.string(forKey: "mouse.gyroActivationSlot1") ?? "zl") ?? .zl
        let activationSlot2 = GyroActivationBinding(rawValue: defaults.string(forKey: "mouse.gyroActivationSlot2") ?? "none") ?? .none
        let activationSlot3 = GyroActivationBinding(rawValue: defaults.string(forKey: "mouse.gyroActivationSlot3") ?? "none") ?? .none
        setMouseMode(mode)
        setMouseSource(opticalSource)
        setPointerMethod(method)
        setGyroMouseSource(gyroSource)
        setGyroOutputMode(gyroOutput)
        setGyroStickSettings(fullRate: gyroStickFullRate,
                             minimumOutput: gyroStickMinimumOutput,
                             responseCurve: gyroStickResponseCurve)
        setGyroActivation(mode: activationMode,
                          slot1: activationSlot1,
                          slot2: activationSlot2,
                          slot3: activationSlot3)
        setGyroAimingEnabled(false)
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
    }

    private func handleDaemonTerminated() {
        daemonApplication = nil
        daemonProcess = nil
        outputPipe = nil
        stopDaemonStream()
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
