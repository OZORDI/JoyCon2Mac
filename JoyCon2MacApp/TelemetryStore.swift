import Foundation
import AppKit

// Isolated from DaemonBridge so log spam does not invalidate controller views.
// Only SettingsView / LogsView subscribes to this. High-frequency telemetry
// lines used to re-render Gamepad/Gyro/Mouse views at 100s of Hz and made
// them feel frozen even though underlying data was updating fine.
class TelemetryStore: ObservableObject {
    static let shared = TelemetryStore()

    @Published private(set) var displayedOutput: String = ""
    @Published private(set) var driverInstallStatus: String = ""
    @Published private(set) var telemetryLineCount: Int = 0

    // Ring buffer so memory stays bounded without publishing on every append.
    private var pendingLines: [String] = []
    private var coalesceTimer: Timer?
    private let maxStoredLines = 600
    private let coalesceInterval: TimeInterval = 0.2
    private init() {}

    func append(_ line: String) {
        guard !line.isEmpty else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.appendOnMain(line)
            }
            return
        }
        appendOnMain(line)
    }

    private func appendOnMain(_ line: String) {
        pendingLines.append(line)
        if pendingLines.count > maxStoredLines * 2 {
            pendingLines.removeFirst(pendingLines.count - maxStoredLines)
        }
        scheduleFlush()
    }

    func updateDriverStatus(_ status: String) {
        DispatchQueue.main.async {
            self.driverInstallStatus = status
        }
    }

    func clear() {
        pendingLines.removeAll()
        coalesceTimer?.invalidate()
        coalesceTimer = nil
        DispatchQueue.main.async {
            self.displayedOutput = ""
            self.telemetryLineCount = 0
        }
    }

    func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayedOutput, forType: .string)
    }

    private func scheduleFlush() {
        if coalesceTimer != nil { return }
        let timer = Timer(timeInterval: coalesceInterval, repeats: false) { [weak self] _ in
            self?.flush()
        }
        coalesceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func flush() {
        coalesceTimer = nil
        guard !pendingLines.isEmpty else { return }
        let batch = pendingLines
        pendingLines.removeAll(keepingCapacity: true)
        DispatchQueue.main.async {
            var combined = self.displayedOutput + batch.joined(separator: "\n") + "\n"
            if combined.count > 40_000 {
                combined = String(combined.suffix(40_000))
            }
            self.displayedOutput = combined
            self.telemetryLineCount &+= batch.count
        }
    }
}
