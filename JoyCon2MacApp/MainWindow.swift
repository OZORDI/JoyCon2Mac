import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case controllers = "Controllers"
    case gamepad = "Gamepad"
    case mouse = "Mouse"
    case gyro = "Gyro"
    case nfc = "NFC"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .controllers: return "gamecontroller"
        case .gamepad: return "dpad"
        case .mouse: return "computermouse"
        case .gyro: return "gyroscope"
        case .nfc: return "wave.3.right"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var daemonBridge: DaemonBridge
    @State private var selectedSection: AppSection = .controllers

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(spacing: 0) {
                topBar
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 960, minHeight: 640)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("JoyCon2Mac")
                        .font(.headline)
                    Text("Local Driver")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            VStack(spacing: 4) {
                ForEach(AppSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.icon)
                                .frame(width: 20)
                            Text(section.rawValue)
                            Spacer()
                        }
                        .font(.system(size: 14, weight: selectedSection == section ? .semibold : .regular))
                        .foregroundColor(selectedSection == section ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedSection == section ? Color.accentColor.opacity(0.16) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    title: daemonBridge.isDaemonRunning ? "Daemon running" : "Daemon stopped",
                    color: daemonBridge.isDaemonRunning ? .green : .red
                )
                statusRow(
                    title: "\(connectedControllerCount) active controller\(connectedControllerCount == 1 ? "" : "s")",
                    color: connectedControllerCount == 0 ? .secondary : .accentColor
                )
            }
            .padding(12)
        }
        .frame(width: 190)
        .compatGlassPanel(cornerRadius: 0)
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedSection.rawValue)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(sectionSubtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                daemonBridge.isDaemonRunning ? daemonBridge.stopDaemon() : daemonBridge.startDaemon()
            } label: {
                Label(daemonBridge.isDaemonRunning ? "Stop" : "Start",
                      systemImage: daemonBridge.isDaemonRunning ? "stop.fill" : "play.fill")
            }
            .compatGlassButton()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .compatGlassPanel(cornerRadius: 0)
    }

    private var connectedControllerCount: Int {
        daemonBridge.controllers.filter { $0.isConnected }.count
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .controllers:
            ControllersView()
        case .gamepad:
            GamepadView()
        case .mouse:
            MouseView()
        case .gyro:
            GyroView()
        case .nfc:
            NFCView()
        case .settings:
            SettingsView()
        }
    }

    private var sectionSubtitle: String {
        switch selectedSection {
        case .controllers: return "Bluetooth connection, battery, and packet status"
        case .gamepad: return "Combined HID gamepad report"
        case .mouse: return "Optical and free-air gyro pointer output"
        case .gyro: return "IMU motion telemetry"
        case .nfc: return "Vendor NFC report stream"
        case .settings: return "Driver and app preferences"
        }
    }

    private func statusRow(title: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    MainWindow()
        .environmentObject(DaemonBridge.shared)
}
