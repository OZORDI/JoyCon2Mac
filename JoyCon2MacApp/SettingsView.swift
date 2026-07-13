import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("autoReconnect") private var autoReconnect = true
    @AppStorage("showNotifications") private var showNotifications = true
    @AppStorage("sdlOnlyMode") private var sdlOnlyMode = false
    @AppStorage("logLevel") private var logLevel = "Info"
    @AppStorage("deadzone") private var deadzone: Double = 0.08
    @AppStorage("stickSensitivity") private var stickSensitivity: Double = 1.0
    
    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .help("Automatically start JoyCon2Mac when you log in")
                
                Toggle("Auto-Reconnect", isOn: $autoReconnect)
                    .help("Automatically reconnect to paired controllers")
                
                Toggle("Show Notifications", isOn: $showNotifications)
                    .help("Show notifications when controllers connect/disconnect")
            }
            
            Section("Daemon") {
                HStack {
                    Text("Status:")
                    Spacer()
                    Circle()
                        .fill(daemonBridge.isDaemonRunning ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(daemonBridge.isDaemonRunning ? "Running" : "Stopped")
                        .foregroundColor(.secondary)
                }
                
                Picker("Log Level", selection: $logLevel) {
                    Text("Error").tag("Error")
                    Text("Warning").tag("Warning")
                    Text("Info").tag("Info")
                    Text("Debug").tag("Debug")
                }
                
                HStack {
                    Button("Restart Daemon") {
                        daemonBridge.restartDaemon()
                    }
                    
                    Button("View Logs") {
                        showLogs()
                    }
                }
            }

            Section("Virtual Driver") {
                Toggle("SDL Only Mode", isOn: Binding(
                    get: { sdlOnlyMode },
                    set: { enabled in
                        sdlOnlyMode = enabled
                        daemonBridge.setSDLOnlyMode(enabled)
                        daemonBridge.restartDaemon()
                    }
                ))
                .help("Expose only the DualSense-compatible HID device for SDL/cloud clients")

                SettingsActionRow(
                    icon: "puzzlepiece.extension",
                    title: "System Gamepad and Mouse",
                    subtitle: "Install and load the local DriverKit extension so macOS and games can see JoyCon2Mac as a real HID device.",
                    buttonTitle: "Install/Load",
                    role: nil,
                    action: daemonBridge.installAndLoadDriver
                )

                if !daemonBridge.driverInstallStatus.isEmpty {
                    Text(daemonBridge.driverInstallStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Telemetry") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Log File")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(daemonBridge.telemetryLogPath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                HStack {
                    Button("Reveal Log File") {
                        daemonBridge.revealTelemetryLog()
                    }

                    Button("Copy Visible Logs") {
                        daemonBridge.copyTelemetryToClipboard()
                    }

                    Button("Clear View") {
                        daemonBridge.clearTelemetryView()
                    }
                }
            }
            
            Section("Controller") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Deadzone: \(deadzone, specifier: "%.2f")")
                    Slider(value: $deadzone, in: 0.0...0.3, step: 0.01)
                    Text("Ignore small stick movements below this threshold")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stick Sensitivity: \(stickSensitivity, specifier: "%.2f")x")
                    Slider(value: $stickSensitivity, in: 0.5...2.0, step: 0.1)
                    Text("Adjust analog stick response curve")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Button("Calibrate Sticks") {
                    // Open calibration wizard
                }
            }
            
            Section("Data") {
                SettingsActionRow(
                    icon: "square.and.arrow.up",
                    title: "Export Configuration",
                    subtitle: "Save current preferences as JSON.",
                    buttonTitle: "Export",
                    role: nil,
                    action: exportConfig
                )

                SettingsActionRow(
                    icon: "square.and.arrow.down",
                    title: "Import Configuration",
                    subtitle: "Load preferences from a JSON file.",
                    buttonTitle: "Import",
                    role: nil,
                    action: importConfig
                )

                Divider()

                SettingsActionRow(
                    icon: "gamecontroller",
                    title: "Paired Controllers",
                    subtitle: "Remove saved Joy-Con pairing records.",
                    buttonTitle: "Clear",
                    role: .destructive,
                    action: clearPairedControllers
                )

                SettingsActionRow(
                    icon: "arrow.counterclockwise",
                    title: "Defaults",
                    subtitle: "Restore app preferences to their initial values.",
                    buttonTitle: "Reset",
                    role: .destructive,
                    action: resetToDefaults
                )
            }
            
            Section("About") {
                HStack {
                    Text("Version:")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Build:")
                    Spacer()
                    Text("2026.05.05")
                        .foregroundColor(.secondary)
                }
                
                Link("GitHub Repository", destination: URL(string: "https://github.com/OZORDI/JoyCon2Mac")!)
                
                Link("Report Issue", destination: URL(string: "https://github.com/OZORDI/JoyCon2Mac/issues/new")!)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 600)
    }
    
    func showLogs() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Daemon Logs"
        window.contentView = NSHostingView(rootView: LogsView().environmentObject(daemonBridge))
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    
    func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "joycon2mac_config.json"
        panel.allowedContentTypes = [.json]
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                // Export configuration
                let config: [String: Any] = [
                    "launchAtLogin": launchAtLogin,
                    "autoReconnect": autoReconnect,
                    "showNotifications": showNotifications,
                    "sdlOnlyMode": sdlOnlyMode,
                    "logLevel": logLevel,
                    "deadzone": deadzone,
                    "stickSensitivity": stickSensitivity
                ]
                
                if let data = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) {
                    try? data.write(to: url)
                }
            }
        }
    }
    
    func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                // Import configuration
                if let data = try? Data(contentsOf: url),
                   let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    launchAtLogin = config["launchAtLogin"] as? Bool ?? false
                    autoReconnect = config["autoReconnect"] as? Bool ?? true
                    showNotifications = config["showNotifications"] as? Bool ?? true
                    sdlOnlyMode = config["sdlOnlyMode"] as? Bool ?? false
                    daemonBridge.setSDLOnlyMode(sdlOnlyMode)
                    logLevel = config["logLevel"] as? String ?? "Info"
                    deadzone = config["deadzone"] as? Double ?? 0.08
                    stickSensitivity = config["stickSensitivity"] as? Double ?? 1.0
                }
            }
        }
    }
    
    func clearPairedControllers() {
        let alert = NSAlert()
        alert.messageText = "Clear Paired Controllers?"
        alert.informativeText = "This will remove all paired controllers. You'll need to pair them again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            // Clear paired controllers from UserDefaults
            UserDefaults.standard.removeObject(forKey: "PairedControllers")
        }
    }
    
    func resetToDefaults() {
        let alert = NSAlert()
        alert.messageText = "Reset to Defaults?"
        alert.informativeText = "This will reset all settings to their default values."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            launchAtLogin = false
            autoReconnect = true
            showNotifications = true
            sdlOnlyMode = false
            daemonBridge.setSDLOnlyMode(false)
            logLevel = "Info"
            deadzone = 0.08
            stickSensitivity = 1.0
        }
    }
}

struct SettingsActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let buttonTitle: String
    let role: ButtonRole?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(role == .destructive ? .red : .accentColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill((role == .destructive ? Color.red : Color.accentColor).opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 16)

            Button(role: role, action: action) {
                Text(buttonTitle)
                    .frame(minWidth: 72)
            }
        }
        .padding(.vertical, 4)
    }
}

struct LogsView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge
    @ObservedObject private var telemetry = TelemetryStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("JoyCon2Mac Telemetry")
                        .font(.headline)
                    Text(daemonBridge.telemetryLogPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Reveal") {
                    daemonBridge.revealTelemetryLog()
                }
                Button("Copy") {
                    daemonBridge.copyTelemetryToClipboard()
                }
                Button("Clear") {
                    daemonBridge.clearTelemetryView()
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(telemetry.displayedOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: telemetry.telemetryLineCount) { _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .background(Color(NSColor.textBackgroundColor))
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(DaemonBridge.shared)
}
