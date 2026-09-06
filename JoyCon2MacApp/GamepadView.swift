import SwiftUI

struct GamepadView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge
    @EnvironmentObject var controllerStore: ControllerStore
    @AppStorage("railBinding.leftSL") private var leftSLBinding = RailBindingTarget.none.rawValue
    @AppStorage("railBinding.leftSR") private var leftSRBinding = RailBindingTarget.none.rawValue
    @AppStorage("railBinding.rightSL") private var rightSLBinding = RailBindingTarget.none.rawValue
    @AppStorage("railBinding.rightSR") private var rightSRBinding = RailBindingTarget.none.rawValue
    @State private var captureSource: RailButtonSource?
    @State private var captureNeedsRelease = false

    private var leftController: ControllerState? {
        controllerStore.controllers.first { $0.side == "left" }
    }

    private var rightController: ControllerState? {
        controllerStore.controllers.first { $0.side == "right" }
    }

    private var primaryController: ControllerState? {
        leftController ?? rightController ?? controllerStore.controllers.first
    }

    private var leftButtons: UInt32 {
        leftController?.leftButtons ?? primaryController?.leftButtons ?? 0
    }

    private var rightButtons: UInt32 {
        rightController?.rightButtons ?? primaryController?.rightButtons ?? 0
    }

    var body: some View {
        Group {
            if primaryController == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        controllerSurface
                        findControls
                        shoulderSection
                        railButtons
                        systemButtons
                    }
                    .padding(20)
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .onAppear {
            syncRailBindings()
        }
        .onChange(of: buttonSnapshotKey) { _ in
            handleCaptureUpdate()
        }
        .onChange(of: leftSLBinding) { _ in syncRailBindings() }
        .onChange(of: leftSRBinding) { _ in syncRailBindings() }
        .onChange(of: rightSLBinding) { _ in syncRailBindings() }
        .onChange(of: rightSRBinding) { _ in syncRailBindings() }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48, weight: .medium))
                .foregroundColor(.secondary)
            Text("No Controller Connected")
                .font(.title3)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controllerSurface: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Combined Output")
                    .font(.headline)
                Spacer()
                Text(connectionSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)

                HStack(alignment: .center, spacing: 42) {
                    VStack(spacing: 18) {
                        dpad
                        StickIndicator(
                            title: "Left Stick",
                            x: leftController?.leftStickX ?? primaryController?.leftStickX ?? 0,
                            y: leftController?.leftStickY ?? primaryController?.leftStickY ?? 0,
                            color: .blue
                        )
                    }

                    Spacer()

                    VStack(spacing: 18) {
                        faceButtons
                        StickIndicator(
                            title: "Right Stick",
                            x: rightController?.rightStickX ?? primaryController?.rightStickX ?? 0,
                            y: rightController?.rightStickY ?? primaryController?.rightStickY ?? 0,
                            color: .green
                        )
                    }
                }
                .padding(28)
            }
            .frame(minHeight: 330)
            .compatGlassPanel(cornerRadius: 8)
        }
    }

    private var findControls: some View {
        HStack(alignment: .center, spacing: 12) {
            Label(findStatusText, systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
                .foregroundColor(.primary)

            Spacer()

            Button {
                daemonBridge.setFindJoyCon(left: true, right: false)
            } label: {
                Label("Find Left", systemImage: "speaker.wave.2.fill")
            }
            .compatGlassButton()
            .disabled(leftController == nil)

            Button {
                daemonBridge.setFindJoyCon(left: false, right: true)
            } label: {
                Label("Find Right", systemImage: "speaker.wave.2.fill")
            }
            .compatGlassButton()
            .disabled(rightController == nil)

            Button {
                daemonBridge.setFindJoyCon(left: true, right: true)
            } label: {
                Label("Find Both", systemImage: "speaker.wave.3.fill")
            }
            .compatGlassButton()
            .disabled(leftController == nil && rightController == nil)

            Button {
                daemonBridge.setFindJoyCon(left: false, right: false)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .compatGlassButton()
            .disabled(!daemonBridge.findingLeftJoyCon && !daemonBridge.findingRightJoyCon)
        }
        .padding(14)
        .compatGlassPanel(cornerRadius: 10)
    }

    private var dpad: some View {
        VStack(spacing: 5) {
            ButtonIndicator(isPressed: leftButtons & 0x0002 != 0, label: "↑")
            HStack(spacing: 5) {
                ButtonIndicator(isPressed: leftButtons & 0x0008 != 0, label: "←")
                Color.clear.frame(width: 34, height: 34)
                ButtonIndicator(isPressed: leftButtons & 0x0004 != 0, label: "→")
            }
            ButtonIndicator(isPressed: leftButtons & 0x0001 != 0, label: "↓")
        }
    }

    private var faceButtons: some View {
        VStack(spacing: 5) {
            ButtonIndicator(isPressed: rightButtons & 0x000200 != 0, label: "X", color: .blue)
            HStack(spacing: 5) {
                ButtonIndicator(isPressed: rightButtons & 0x000100 != 0, label: "Y", color: .green)
                Color.clear.frame(width: 34, height: 34)
                ButtonIndicator(isPressed: rightButtons & 0x000800 != 0, label: "A", color: .red)
            }
            ButtonIndicator(isPressed: rightButtons & 0x000400 != 0, label: "B", color: .yellow)
        }
    }

    private var shoulderSection: some View {
        HStack(alignment: .top, spacing: 16) {
            ShoulderGroup(
                title: "Left Shoulder",
                primaryLabel: "L",
                primaryPressed: leftButtons & 0x0040 != 0,
                secondaryLabel: "ZL",
                secondaryPressed: leftButtons & 0x0080 != 0,
                triggerValue: leftController?.triggerL ?? primaryController?.triggerL ?? 0
            )

            ShoulderGroup(
                title: "Right Shoulder",
                primaryLabel: "R",
                primaryPressed: rightButtons & 0x004000 != 0,
                secondaryLabel: "ZR",
                secondaryPressed: rightButtons & 0x008000 != 0,
                triggerValue: rightController?.triggerR ?? primaryController?.triggerR ?? 0
            )
        }
    }

    private var railButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Side Rail Buttons")
                    .font(.headline)
                Spacer()
                if let captureSource {
                    Text("Press target for \(captureSource.title)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 12) {
                ButtonIndicator(isPressed: leftButtons & 0x0020 != 0, label: "SL L", color: .purple)
                ButtonIndicator(isPressed: leftButtons & 0x0010 != 0, label: "SR L", color: .purple)
                ButtonIndicator(isPressed: rightButtons & 0x002000 != 0, label: "SL R", color: .blue)
                ButtonIndicator(isPressed: rightButtons & 0x001000 != 0, label: "SR R", color: .blue)
            }

            VStack(spacing: 8) {
                ForEach(RailButtonSource.allCases) { source in
                    railBindingRow(source)
                }
            }
        }
        .padding(14)
        .compatGlassPanel(cornerRadius: 8)
    }

    private func railBindingRow(_ source: RailButtonSource) -> some View {
        let target = RailBindingTarget(rawValue: bindingValue(for: source)) ?? .none
        return HStack(spacing: 10) {
            ButtonIndicator(isPressed: source.isPressed(leftButtons: leftButtons, rightButtons: rightButtons),
                            label: source.shortLabel,
                            color: source.sideColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(target.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                beginCapture(for: source)
            } label: {
                Label(captureSource == source ? "Listening" : "Bind",
                      systemImage: captureSource == source ? "record.circle" : "arrow.triangle.2.circlepath")
            }
            .compatGlassButton()

            Button {
                setBinding(.none, for: source)
            } label: {
                Label("Clear", systemImage: "xmark")
            }
            .compatGlassButton()
            .disabled(target == .none)
        }
        .padding(.vertical, 2)
    }

    private var systemButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Buttons")
                .font(.headline)

            HStack(spacing: 12) {
                ButtonIndicator(isPressed: leftButtons & 0x0100 != 0, label: "−", color: .gray)
                ButtonIndicator(isPressed: rightButtons & 0x000002 != 0, label: "+", color: .gray)
                ButtonIndicator(isPressed: leftButtons & 0x2000 != 0, label: "CAP", color: .gray)
                ButtonIndicator(isPressed: rightButtons & 0x000010 != 0, label: "HOME", color: .gray)
                ButtonIndicator(isPressed: leftButtons & 0x0800 != 0, label: "L3", color: .gray)
                ButtonIndicator(isPressed: rightButtons & 0x000004 != 0, label: "R3", color: .gray)
            }
        }
        .padding(14)
        .compatGlassPanel(cornerRadius: 8)
    }

    private var connectionSummary: String {
        let left = leftController.map { "L \($0.packetCount)" } ?? "L missing"
        let right = rightController.map { "R \($0.packetCount)" } ?? "R missing"
        return "\(left) · \(right)"
    }

    private var findStatusText: String {
        switch (daemonBridge.findingLeftJoyCon, daemonBridge.findingRightJoyCon) {
        case (true, true): return "Finding both Joy-Cons"
        case (true, false): return "Finding left Joy-Con"
        case (false, true): return "Finding right Joy-Con"
        case (false, false): return "Find Joy-Cons"
        }
    }

    private var buttonSnapshotKey: String {
        "\(leftButtons):\(rightButtons)"
    }

    private var railBindingsPayload: [String: String] {
        [
            "leftSL": leftSLBinding,
            "leftSR": leftSRBinding,
            "rightSL": rightSLBinding,
            "rightSR": rightSRBinding
        ]
    }

    private func bindingValue(for source: RailButtonSource) -> String {
        switch source {
        case .leftSL: return leftSLBinding
        case .leftSR: return leftSRBinding
        case .rightSL: return rightSLBinding
        case .rightSR: return rightSRBinding
        }
    }

    private func setBinding(_ target: RailBindingTarget, for source: RailButtonSource) {
        switch source {
        case .leftSL: leftSLBinding = target.rawValue
        case .leftSR: leftSRBinding = target.rawValue
        case .rightSL: rightSLBinding = target.rawValue
        case .rightSR: rightSRBinding = target.rawValue
        }
    }

    private func syncRailBindings() {
        daemonBridge.setRailBindings(railBindingsPayload)
    }

    private func beginCapture(for source: RailButtonSource) {
        captureSource = source
        captureNeedsRelease = RailBindingTarget.detect(leftButtons: leftButtons, rightButtons: rightButtons) != nil
        handleCaptureUpdate()
    }

    private func handleCaptureUpdate() {
        guard let source = captureSource else { return }
        let target = RailBindingTarget.detect(leftButtons: leftButtons, rightButtons: rightButtons)
        if captureNeedsRelease {
            if target == nil {
                captureNeedsRelease = false
            }
            return
        }
        guard let target else { return }
        setBinding(target, for: source)
        captureSource = nil
        captureNeedsRelease = false
    }
}

private enum RailButtonSource: String, CaseIterable, Identifiable {
    case leftSL
    case leftSR
    case rightSL
    case rightSR

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftSL: return "Left SL"
        case .leftSR: return "Left SR"
        case .rightSL: return "Right SL"
        case .rightSR: return "Right SR"
        }
    }

    var shortLabel: String {
        switch self {
        case .leftSL: return "SL L"
        case .leftSR: return "SR L"
        case .rightSL: return "SL R"
        case .rightSR: return "SR R"
        }
    }

    var sideColor: Color {
        switch self {
        case .leftSL, .leftSR: return .purple
        case .rightSL, .rightSR: return .blue
        }
    }

    func isPressed(leftButtons: UInt32, rightButtons: UInt32) -> Bool {
        switch self {
        case .leftSL: return leftButtons & 0x0020 != 0
        case .leftSR: return leftButtons & 0x0010 != 0
        case .rightSL: return rightButtons & 0x002000 != 0
        case .rightSR: return rightButtons & 0x001000 != 0
        }
    }
}

private enum RailBindingTarget: String, CaseIterable, Identifiable {
    case none
    case cross
    case circle
    case square
    case triangle
    case l1
    case r1
    case l2
    case r2
    case share
    case options
    case l3
    case r3
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
    case home
    case capture

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "No output"
        case .cross: return "Cross"
        case .circle: return "Circle"
        case .square: return "Square"
        case .triangle: return "Triangle"
        case .l1: return "L1"
        case .r1: return "R1"
        case .l2: return "L2"
        case .r2: return "R2"
        case .share: return "Share"
        case .options: return "Options"
        case .l3: return "L3"
        case .r3: return "R3"
        case .dpadUp: return "D-pad Up"
        case .dpadDown: return "D-pad Down"
        case .dpadLeft: return "D-pad Left"
        case .dpadRight: return "D-pad Right"
        case .home: return "Home"
        case .capture: return "Capture"
        }
    }

    static func detect(leftButtons: UInt32, rightButtons: UInt32) -> RailBindingTarget? {
        if rightButtons & 0x000400 != 0 { return .cross }
        if rightButtons & 0x000800 != 0 { return .circle }
        if rightButtons & 0x000100 != 0 { return .square }
        if rightButtons & 0x000200 != 0 { return .triangle }
        if leftButtons & 0x0040 != 0 { return .l1 }
        if rightButtons & 0x004000 != 0 { return .r1 }
        if leftButtons & 0x0080 != 0 { return .l2 }
        if rightButtons & 0x008000 != 0 { return .r2 }
        if leftButtons & 0x0100 != 0 { return .share }
        if rightButtons & 0x000002 != 0 { return .options }
        if leftButtons & 0x0800 != 0 { return .l3 }
        if rightButtons & 0x000004 != 0 { return .r3 }
        if leftButtons & 0x0002 != 0 { return .dpadUp }
        if leftButtons & 0x0001 != 0 { return .dpadDown }
        if leftButtons & 0x0008 != 0 { return .dpadLeft }
        if leftButtons & 0x0004 != 0 { return .dpadRight }
        if rightButtons & 0x000010 != 0 { return .home }
        if leftButtons & 0x2000 != 0 { return .capture }
        return nil
    }
}

private struct ShoulderGroup: View {
    let title: String
    let primaryLabel: String
    let primaryPressed: Bool
    let secondaryLabel: String
    let secondaryPressed: Bool
    let triggerValue: UInt8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            HStack(spacing: 12) {
                ButtonIndicator(isPressed: primaryPressed, label: primaryLabel, color: .purple)
                ButtonIndicator(isPressed: secondaryPressed, label: secondaryLabel, color: .purple)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Analog")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(triggerValue)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                TriggerMeter(value: triggerValue, color: .purple)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatGlassPanel(cornerRadius: 8)
    }
}

private struct TriggerMeter: View {
    let value: UInt8
    let color: Color

    private var normalizedValue: CGFloat {
        CGFloat(value) / 255.0
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: proxy.size.width * normalizedValue)
            }
        }
        .frame(height: 6)
    }
}

private struct StickIndicator: View {
    let title: String
    let x: Int16
    let y: Int16
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.16))
                    .frame(width: 108, height: 108)
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 1)
                    .frame(width: 108, height: 108)
                Circle()
                    .fill(color)
                    .frame(width: 18, height: 18)
                    // UI-only axis remap. Y needed flipping on its own —
                    // the decoder emits joycon2cpp's `-y * 32767`, which
                    // games/DS4 want but which the SwiftUI screen-space
                    // rendered upside down. X is already correct as-is:
                    // tilt right → outX positive → dot offsets right.
                    // Keeping this comment because I broke this twice by
                    // negating X "to be consistent".
                    .offset(
                        x: CGFloat(x) / 32767 * 42,
                        y: CGFloat(y) / 32767 * 42
                    )
            }

            VStack(spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(x), \(y)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

struct ButtonIndicator: View {
    let isPressed: Bool
    let label: String
    var color: Color = .blue

    var body: some View {
        Text(label)
            .font(.system(size: label.count > 3 ? 10 : 13, weight: .semibold))
            .foregroundColor(isPressed ? .white : .secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: 38, height: 38)
            .background(isPressed ? color : Color.secondary.opacity(0.18))
            .clipShape(Circle())
    }
}

#Preview {
    GamepadView()
        .environmentObject(DaemonBridge.shared)
        .environmentObject(DaemonBridge.shared.controllerStore)
        .frame(width: 800, height: 600)
}
