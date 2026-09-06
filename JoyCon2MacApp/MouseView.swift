import SwiftUI

struct MouseView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge
    @EnvironmentObject var controllerStore: ControllerStore
    @AppStorage("mouse.gyroOutputMode") private var gyroOutputModeRaw = GyroOutputMode.mouse.rawValue
    @AppStorage("mouse.gyroStickFullRate") private var gyroStickFullRate = 180.0
    @AppStorage("mouse.gyroStickMinimumOutput") private var gyroStickMinimumOutput = 0.12
    @AppStorage("mouse.gyroStickResponseCurve") private var gyroStickResponseCurve = 1.0

    private var leftController: ControllerState? {
        controllerStore.controllers.first(where: { $0.side == "left" })
    }
    private var rightController: ControllerState? {
        controllerStore.controllers.first(where: { $0.side == "right" })
    }
    // Source / mode live on the first controller. Any controller works —
    // the daemon is the authority, the `controllers[*].mouseSource` field
    // is just a mirror and both rows get updated together when the user
    // changes the picker.
    private var mouseMode: MouseMode {
        controllerStore.controllers.first?.mouseMode ?? .normal
    }
    private var mouseSource: MouseSource {
        controllerStore.controllers.first?.mouseSource ?? .auto
    }
    private var activeSide: String {
        controllerStore.controllers.first?.mouseActiveSide ?? "right"
    }
    private var pointerMethod: PointerMethod {
        controllerStore.controllers.first?.pointerMethod ?? .optical
    }
    private var gyroSource: GyroMouseSource {
        controllerStore.controllers.first?.gyroMouseSource ?? .fused
    }
    private var gyroOutputMode: GyroOutputMode {
        GyroOutputMode(rawValue: gyroOutputModeRaw) ?? .mouse
    }
    private var gyroEnabled: Bool {
        controllerStore.controllers.first?.gyroAimingEnabled ?? false
    }
    private var gyroOutputActive: Bool {
        controllerStore.controllers.first?.gyroOutputActive ?? false
    }
    private var gyroCalibrating: Bool {
        controllerStore.controllers.first?.gyroCalibrating ?? true
    }
    private var gyroActiveSource: String {
        controllerStore.controllers.first?.gyroActiveSource ?? "none"
    }
    private var gyroActivationMode: GyroActivationMode {
        controllerStore.controllers.first?.gyroActivationMode ?? .hold
    }
    private var gyroActivationSlot1: GyroActivationBinding {
        controllerStore.controllers.first?.gyroActivationSlot1 ?? .zl
    }
    private var gyroActivationSlot2: GyroActivationBinding {
        controllerStore.controllers.first?.gyroActivationSlot2 ?? .none
    }
    private var gyroActivationSlot3: GyroActivationBinding {
        controllerStore.controllers.first?.gyroActivationSlot3 ?? .none
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                Divider()
                pointerMethodPicker

                if pointerMethod == .optical || gyroOutputMode == .mouse {
                    Divider()
                    modePicker
                }

                Divider()
                if pointerMethod == .optical {
                    sourcePicker
                } else {
                    gyroAimingControls
                }

                Divider()
                buttonMapping

                Divider()
                testArea

                Spacer()
            }
            .padding()
        }
    }

    private var header: some View {
        HStack {
            Text("Mouse Configuration")
                .font(.title)
                .fontWeight(.bold)

            Spacer()

            Button {
                if pointerMethod == .gyroAiming {
                    daemonBridge.setGyroAimingEnabled(!gyroEnabled)
                } else {
                    daemonBridge.toggleMouseMode()
                }
            } label: {
                Label(pointerMethod == .gyroAiming
                      ? (gyroEnabled ? "Stop Aiming" : "Start Aiming")
                      : "Cycle Mode",
                      systemImage: pointerMethod == .gyroAiming
                      ? (gyroEnabled ? "stop.fill" : "scope")
                      : "computermouse.fill")
            }
            .buttonStyle(.bordered)
        }
    }

    private var pointerMethodPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pointer Input")
                .font(.headline)
            Picker("Pointer Input", selection: Binding<PointerMethod>(
                get: { pointerMethod },
                set: { daemonBridge.setPointerMethod($0) }
            )) {
                Text("Optical").tag(PointerMethod.optical)
                Text("Gyro Aiming").tag(PointerMethod.gyroAiming)
            }
            .pickerStyle(.segmented)
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mouse Mode")
                .font(.headline)

            // Binding goes directly through setMouseMode() which forwards
            // to the daemon's control channel. Picker tag ordering matches
            // the daemon-authoritative enum (OFF / FAST / NORMAL / SLOW).
            Picker("Mode", selection: Binding<MouseMode>(
                get: { mouseMode },
                set: { daemonBridge.setMouseMode($0) }
            )) {
                Text("Off").tag(MouseMode.off)
                Text("Slow").tag(MouseMode.slow)
                Text("Normal").tag(MouseMode.normal)
                Text("Fast").tag(MouseMode.fast)
            }
            .pickerStyle(.segmented)

            Text(pointerMethod == .optical
                 ? "Press Chat (C) on the Right Joy-Con to cycle modes."
                 : "The selected preset controls free-air pointer speed.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var gyroAimingControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Gyro Source")
                    .font(.headline)
                Spacer()
                Label(gyroStatusText, systemImage: gyroStatusIcon)
                    .font(.caption)
                    .foregroundColor(gyroOutputActive ? .green : (gyroEnabled ? .orange : .secondary))
            }

            Picker("Gyro Source", selection: Binding<GyroMouseSource>(
                get: { gyroSource },
                set: { daemonBridge.setGyroMouseSource($0) }
            )) {
                Text("Fused").tag(GyroMouseSource.fused)
                Text("Left Joy-Con").tag(GyroMouseSource.left)
                Text("Right Joy-Con").tag(GyroMouseSource.right)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 10) {
                Text("Output")
                    .font(.subheadline.weight(.semibold))
                Picker("Output", selection: Binding<GyroOutputMode>(
                    get: { gyroOutputMode },
                    set: {
                        gyroOutputModeRaw = $0.rawValue
                        daemonBridge.setGyroOutputMode($0)
                    }
                )) {
                    Text("Mouse Cursor").tag(GyroOutputMode.mouse)
                    Text("Right Stick").tag(GyroOutputMode.rightStick)
                }
                .pickerStyle(.segmented)
            }

            if gyroOutputMode == .rightStick {
                gyroStickControls
            }

            HStack(spacing: 12) {
                Button {
                    daemonBridge.setGyroAimingEnabled(!gyroEnabled)
                } label: {
                    Label(gyroEnabled ? "Stop" : "Start",
                          systemImage: gyroEnabled ? "stop.fill" : "scope")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    daemonBridge.calibrateGyroPointer()
                } label: {
                    Label("Calibrate", systemImage: "scope")
                }
                .buttonStyle(.bordered)
            }

            Text(gyroOutputMode == .mouse
                 ? "Hold the selected Joy-Con still while calibrating. Rotation moves the pointer; stopping rotation stops it."
                 : "Gyro aiming is added to the physical right stick. Releasing both inputs returns the stick to center.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text("Activation")
                    .font(.subheadline.weight(.semibold))
                Picker("Activation", selection: Binding<GyroActivationMode>(
                    get: { gyroActivationMode },
                    set: { applyGyroActivation(mode: $0) }
                )) {
                    ForEach(GyroActivationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if gyroActivationMode != .continuous {
                    activationBindingPicker("Primary", selection: Binding(
                        get: { gyroActivationSlot1 },
                        set: { applyGyroActivation(slot1: $0) }
                    ))
                    activationBindingPicker("Secondary", selection: Binding(
                        get: { gyroActivationSlot2 },
                        set: { applyGyroActivation(slot2: $0) }
                    ))
                    activationBindingPicker("Tertiary", selection: Binding(
                        get: { gyroActivationSlot3 },
                        set: { applyGyroActivation(slot3: $0) }
                    ))
                }

                Text(gyroActivationHelpText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var gyroStickControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Full Stick Rate")
                Spacer()
                Text("\(Int(gyroStickFullRate)) deg/s")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(
                get: { gyroStickFullRate },
                set: {
                    gyroStickFullRate = $0
                    applyGyroStickSettings()
                }
            ), in: 30...720, step: 10)

            HStack {
                Text("Minimum Output")
                Spacer()
                Text(gyroStickMinimumOutput.formatted(.number.precision(.fractionLength(2))))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(
                get: { gyroStickMinimumOutput },
                set: {
                    gyroStickMinimumOutput = $0
                    applyGyroStickSettings()
                }
            ), in: 0...0.5, step: 0.01)

            HStack {
                Text("Response Curve")
                Spacer()
                Text(gyroStickResponseCurve.formatted(.number.precision(.fractionLength(2))))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(
                get: { gyroStickResponseCurve },
                set: {
                    gyroStickResponseCurve = $0
                    applyGyroStickSettings()
                }
            ), in: 0.25...4, step: 0.05)
        }
    }

    private func activationBindingPicker(_ title: String,
                                         selection: Binding<GyroActivationBinding>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(GyroActivationBinding.allCases) { binding in
                    Text(binding.label).tag(binding)
                }
            }
            .labelsHidden()
            .frame(width: 190)
        }
    }

    private func applyGyroActivation(mode: GyroActivationMode? = nil,
                                     slot1: GyroActivationBinding? = nil,
                                     slot2: GyroActivationBinding? = nil,
                                     slot3: GyroActivationBinding? = nil) {
        daemonBridge.setGyroActivation(
            mode: mode ?? gyroActivationMode,
            slot1: slot1 ?? gyroActivationSlot1,
            slot2: slot2 ?? gyroActivationSlot2,
            slot3: slot3 ?? gyroActivationSlot3
        )
    }

    private var gyroActivationButtonSummary: String {
        let labels = [gyroActivationSlot1, gyroActivationSlot2, gyroActivationSlot3]
            .filter { $0 != .none }
            .map(\.label)
        return labels.isEmpty ? "a configured button" : labels.joined(separator: " or ")
    }

    private var gyroActivationHelpText: String {
        switch gyroActivationMode {
        case .continuous:
            return "Gyro output remains active whenever Gyro Aiming is started."
        case .hold:
            return "Hold \(gyroActivationButtonSummary) to activate gyro output. The buttons still pass through to games."
        case .toggle:
            return "Press \(gyroActivationButtonSummary) to toggle gyro output. The buttons still pass through to games."
        }
    }

    private func applyGyroStickSettings() {
        daemonBridge.setGyroStickSettings(
            fullRate: gyroStickFullRate,
            minimumOutput: gyroStickMinimumOutput,
            responseCurve: gyroStickResponseCurve
        )
    }

    private var gyroStatusText: String {
        if gyroCalibrating { return "Calibrating" }
        if !gyroEnabled { return "Stopped" }
        if gyroOutputActive { return "Active: \(gyroActiveSource.capitalized)" }
        switch gyroActivationMode {
        case .continuous: return "Starting"
        case .hold: return "Waiting for Hold"
        case .toggle: return "Ready to Toggle"
        }
    }

    private var gyroStatusIcon: String {
        if gyroCalibrating { return "circle.dotted" }
        if gyroOutputActive { return "scope" }
        return gyroEnabled ? "hand.raised.fill" : "pause.circle"
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Mouse Source")
                    .font(.headline)
                Spacer()
                // Active-side pill. Shows which Joy-Con is currently being
                // used as the mouse right now (in Auto it flips whenever the
                // other one is placed on a surface).
                Text("Active: \(activeSide.capitalized)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(activeSide == "left" ? Color.blue.opacity(0.2) : Color.green.opacity(0.2))
                    .clipShape(Capsule())
            }

            Picker("Source", selection: Binding<MouseSource>(
                get: { mouseSource },
                set: { daemonBridge.setMouseSource($0) }
            )) {
                Text("Auto").tag(MouseSource.auto)
                Text("Left Joy-Con").tag(MouseSource.left)
                Text("Right Joy-Con").tag(MouseSource.right)
            }
            .pickerStyle(.segmented)

            Text("Auto picks whichever Joy-Con is resting on a surface (distance == 0). Switch sides any time without unpairing — the optical baseline resets on every switch so the cursor won't jump.")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Hold L + ZL or R + ZR on the active optical Joy-Con while moving it to invoke system swipes: left/right changes Spaces, up opens Mission Control, and down opens App Expose.")
                .font(.caption)
                .foregroundColor(.secondary)

            // Per-side surface read-out. distance==0 means the Joy-Con
            // is touching a surface; distance>0 (~12) means it's
            // airborne at that distance. Auto adopts whichever side has
            // distance==0 consistently.
            HStack(spacing: 14) {
                surfaceBadge(side: "left", distance: leftController?.mouseDistance ?? 0)
                surfaceBadge(side: "right", distance: rightController?.mouseDistance ?? 0)
            }
        }
    }

    private func surfaceBadge(side: String, distance: Int16) -> some View {
        // Byte 0x17 is the optical sensor's distance reading. Zero means
        // the Joy-Con is physically touching a surface (distance = 0);
        // a non-zero value (~12) means it's airborne at that distance.
        let onSurface = distance == 0
        let isActive = activeSide == side
        return HStack(spacing: 6) {
            Circle()
                .fill(onSurface ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
            Text("\(side.capitalized) · \(onSurface ? "on surface" : "airborne")")
                .font(.caption)
            Text("(d=\(distance))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isActive ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var buttonMapping: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Button Mapping")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                // Mapping depends on which side is the active mouse.
                // joycon2cpp's right layout: R = Left-click, ZR = Right-click, R3 = Middle-click.
                // Matching left layout: L = Left, ZL = Right, L3 = Middle.
                if pointerMethod == .gyroAiming && gyroSource == .fused {
                    mappingRow(from: "L / R", to: "Left Click")
                    mappingRow(from: "ZL / ZR", to: "Right Click")
                    mappingRow(from: "L3 / R3", to: "Middle Click")
                } else {
                    let isLeftMouse = pointerMethod == .gyroAiming
                        ? gyroSource == .left
                        : activeSide == "left"
                    mappingRow(from: isLeftMouse ? "L" : "R", to: "Left Click")
                    mappingRow(from: isLeftMouse ? "ZL" : "ZR", to: "Right Click")
                    mappingRow(from: isLeftMouse ? "L3" : "R3", to: "Middle Click")
                    if pointerMethod == .optical {
                        mappingRow(from: "Joystick Y", to: "Scroll Wheel")
                        mappingRow(from: "Joystick X ± edge", to: "Forward / Back")
                    }
                }
            }
        }
    }

    private func mappingRow(from source: String, to target: String) -> some View {
        HStack {
            Text(source).frame(width: 160, alignment: .leading)
            Image(systemName: "arrow.right").foregroundColor(.secondary)
            Text(target).foregroundColor(.blue)
        }
    }

    private var testArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mouse Test Area")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(height: 200)

                if pointerMethod == .gyroAiming {
                    VStack(spacing: 10) {
                        Image(systemName: "scope")
                            .font(.system(size: 34))
                        Text(gyroEnabled ? "Gyro pointer active" : "Gyro pointer paused")
                            .font(.headline)
                        Text("Source: \(gyroActiveSource.capitalized)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let c = activeSide == "left" ? leftController : rightController {
                    VStack(spacing: 8) {
                        Text("Optical Sensor · \(activeSide.capitalized)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 20) {
                            opticalCell(label: "ΔX", value: "\(c.mouseX)")
                            opticalCell(label: "ΔY", value: "\(c.mouseY)")
                            opticalCell(label: "Distance", value: "\(c.mouseDistance)")
                        }

                        Text("Move the active Joy-Con over a surface to test.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("No controller connected")
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func opticalCell(label: String, value: String) -> some View {
        VStack {
            Text(label).font(.caption)
            Text(value).font(.title2).monospacedDigit()
        }
    }
}

#Preview {
    MouseView()
        .environmentObject(DaemonBridge.shared)
        .environmentObject(DaemonBridge.shared.controllerStore)
        .frame(width: 800, height: 600)
}
