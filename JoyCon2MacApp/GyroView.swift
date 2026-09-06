import SwiftUI

// ─── Joy-Con 2 IMU axis convention ───────────────────────────────────────
//
// The joycon2cpp reference (our known-good Switch 2 implementation) reads
// both Joy-Cons' accel/gyro as raw int16 at the same packet offsets and
// pipes them straight into a DS4 report without any per-side sign flip:
//
//   accel X/Y/Z  at 0x30 / 0x32 / 0x34   (scale: 4096 = 1 G)
//   gyro  X/Y/Z  at 0x36 / 0x38 / 0x3A   (scale: 48000 = 360 °/s)
//
// (Source: joycon2cpp/README.md + testapp GenerateDS4Report / GenerateDual-
// JoyConDS4Report, which memcpys wAccelX..wGyroZ one-to-one. Content was
// rephrased for compliance with licensing restrictions.)
//
// The Linux `hid-nintendo` driver DOES negate Y and Z on the original
// Joy-Con (v1) right controller because its IMU chip is physically
// rotated 180° relative to the left. I initially copied that flip here,
// but joycon2cpp (the Switch 2 reference) does not apply it, which
// suggests the Joy-Con 2 IMU mounting differs. We expose both options
// via `invertRightAxes` so the user can verify on real hardware: flat
// on desk, face up → both sides should read accel ≈ (0, 0, +1 G). If
// the right reads (0, 0, -1 G), flip the toggle.
//
// Grip-frame display math. In the Joy-Con grip poses we observed, the user's
// upright/forward tilt lands on the raw Y/Z gravity plane, so the UI presents
// that as pitch. The raw X tilt is presented as roll.
//   pitch = atan2( ay, az)
//   roll  = atan2(-ax, sqrt(ay² + az²))
//   yaw   = ∫ gz dt                        (around Z, drifts — no mag.)

import simd

// Which source feeds the 3D view. Auto uses the fused average of both
// canonicalized sides when both are available, falling back to whichever
// one is streaming data.
enum GyroSource: String, CaseIterable, Identifiable {
    case fused = "Fused"
    case left  = "Left"
    case right = "Right"
    var id: String { rawValue }
}

struct GyroView: View {
    @EnvironmentObject var controllerStore: ControllerStore
    @State private var showRawValues = false
    @State private var gyroSource: GyroSource = .fused
    // Defaults to OFF because joycon2cpp's known-good Switch 2 path does
    // not negate any right-side axes. Flip this if the right Joy-Con's
    // gravity vector points opposite the left when both are flat on the
    // desk — that means the IMU is physically mounted 180° like the
    // original v1 Joy-Con.
    @State private var invertRightAxes: Bool = false

    private var leftController: ControllerState? {
        controllerStore.controllers.first { $0.side == "left" }
    }
    private var rightController: ControllerState? {
        controllerStore.controllers.first { $0.side == "right" }
    }

    private var anyController: ControllerState? {
        leftController ?? rightController
    }

    // Canonicalized readings (accel in G, gyro in °/s).
    private var canonicalLeft: IMUSample? {
        guard let c = leftController, c.isConnected else { return nil }
        return IMUSample(accel: SIMD3(c.accelX, c.accelY, c.accelZ),
                         gyro:  SIMD3(c.gyroX,  c.gyroY,  c.gyroZ))
    }
    private var canonicalRight: IMUSample? {
        guard let c = rightController, c.isConnected else { return nil }
        // joycon2cpp passes raw int16s straight through for both sides, so
        // the default here is "no flip". Enable invertRightAxes if you see
        // the right stick tilt opposite the left when both are held the
        // same way — that would mean the IMU is mounted flipped on this
        // hardware revision.
        let sy: Double = invertRightAxes ? -1 : 1
        let sz: Double = invertRightAxes ? -1 : 1
        return IMUSample(accel: SIMD3(c.accelX, sy * c.accelY, sz * c.accelZ),
                         gyro:  SIMD3(c.gyroX,  sy * c.gyroY,  sz * c.gyroZ))
    }

    // Sample that actually drives the filter, depending on the picker.
    private var fusedSample: IMUSample? {
        switch gyroSource {
        case .left:  return canonicalLeft
        case .right: return canonicalRight
        case .fused:
            if let l = canonicalLeft, let r = canonicalRight {
                return combineSamples(l, r)
            }
            return canonicalLeft ?? canonicalRight
        }
    }

    private func combineSamples(_ left: IMUSample, _ right: IMUSample) -> IMUSample? {
        let leftValid = hasLiveIMU(left)
        let rightValid = hasLiveIMU(right)

        if leftValid && rightValid {
            return IMUSample(accel: (left.accel + right.accel) * 0.5,
                             gyro:  (left.gyro  + right.gyro)  * 0.5)
        }
        if leftValid { return left }
        if rightValid { return right }
        return nil
    }

    private func hasLiveIMU(_ sample: IMUSample) -> Bool {
        simd_length(sample.accel) > 0.05 || simd_length(sample.gyro) > 0.05
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                Divider()

                if anyController != nil {
                    orientationSection
                    Divider()
                    sourceAndBars
                    if showRawValues {
                        Divider()
                        rawValuesSection
                    }
                } else {
                    emptyState
                }

                Spacer()
            }
            .padding()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("Motion Sensors")
                .font(.title)
                .fontWeight(.bold)
            Spacer()
            Toggle("Invert Right Axes", isOn: $invertRightAxes)
                .help("Flip the right Joy-Con's Y and Z axes. Only enable if the right side tilts opposite the left when both are held the same way.")
            Toggle("Show Raw Values", isOn: $showRawValues)
        }
    }

    private var orientationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("3D Orientation")
                    .font(.headline)
                Spacer()
                Picker("Source", selection: $gyroSource) {
                    ForEach(GyroSource.allCases) { src in
                        Text(src.rawValue).tag(src)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(height: 300)

                JoyConOrientationView(sample: fusedSample,
                                      sourceLabel: gyroSource.rawValue)
                    .frame(height: 280)
            }
        }
    }

    private var sourceAndBars: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Gyro axis labels in the grip-frame display convention:
            //   X → pitch rate (upright/forward tilt)
            //   Y → roll rate  (side-to-side tilt)
            //   Z → yaw rate   (spin on table)
            VStack(alignment: .leading, spacing: 12) {
                Text("Gyroscope (°/s) — \(gyroSource.rawValue)")
                    .font(.headline)
                HStack(spacing: 28) {
                    MotionBar(label: "Pitch (X)",
                              value: fusedSample?.gyro.x ?? 0,
                              range: -720...720, color: .red)
                    MotionBar(label: "Roll (Y)",
                              value: fusedSample?.gyro.y ?? 0,
                              range: -720...720, color: .green)
                    MotionBar(label: "Yaw (Z)",
                              value: fusedSample?.gyro.z ?? 0,
                              range: -720...720, color: .blue)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Accelerometer (G) — \(gyroSource.rawValue)")
                    .font(.headline)
                HStack(spacing: 28) {
                    MotionBar(label: "X", value: fusedSample?.accel.x ?? 0,
                              range: -2...2, color: .red)
                    MotionBar(label: "Y", value: fusedSample?.accel.y ?? 0,
                              range: -2...2, color: .green)
                    MotionBar(label: "Z", value: fusedSample?.accel.z ?? 0,
                              range: -2...2, color: .blue)
                }
            }
        }
    }

    private var rawValuesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(invertRightAxes
                 ? "Raw values (right-side Y,Z shown both raw and after the invertRightAxes flip)"
                 : "Raw values (right-side passed through as joycon2cpp does — no flip)")
                .font(.headline)

            rawRow(label: "Left", c: leftController)
            rawRow(label: invertRightAxes ? "Right (raw)" : "Right",
                   c: rightController, canonicalize: false)
            if invertRightAxes {
                rawRow(label: "Right (after Y,Z flip)", c: rightController, canonicalize: true)
            }
        }
    }

    @ViewBuilder
    private func rawRow(label: String, c: ControllerState?, canonicalize: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).foregroundColor(.secondary)
            if let c {
                let ax = c.accelX
                let ay = canonicalize ? -c.accelY : c.accelY
                let az = canonicalize ? -c.accelZ : c.accelZ
                let gx = c.gyroX
                let gy = canonicalize ? -c.gyroY : c.gyroY
                let gz = canonicalize ? -c.gyroZ : c.gyroZ
                Text(String(format: "accel  X=%+.3fG  Y=%+.3fG  Z=%+.3fG", ax, ay, az))
                    .font(.system(.caption, design: .monospaced))
                Text(String(format: "gyro   X=%+7.2f°/s  Y=%+7.2f°/s  Z=%+7.2f°/s", gx, gy, gz))
                    .font(.system(.caption, design: .monospaced))
            } else {
                Text("not connected").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "gyroscope")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("No Controller Connected")
                .font(.title2)
        }
        .frame(height: 400)
    }
}

// MARK: - Sample container

struct IMUSample: Equatable {
    var accel: SIMD3<Double>  // in G (1 G = 1 gravity)
    var gyro:  SIMD3<Double>  // in °/s
}

// MARK: - Bars

struct MotionBar: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let color: Color

    var normalizedValue: Double {
        let clamped = max(range.lowerBound, min(range.upperBound, value))
        return (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(label).font(.caption).foregroundColor(.secondary)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 180, height: 20)
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 1, height: 20)
                    .offset(x: 90)
                Circle()
                    .fill(color)
                    .frame(width: 16, height: 16)
                    .offset(x: normalizedValue * 180 - 8)
            }
            Text(String(format: "%.1f", value))
                .font(.caption).monospacedDigit()
        }
    }
}

// MARK: - Complementary filter (owns orientation state across re-renders)

// Why its own ObservableObject: SwiftUI rebuilds the parent on every @Published
// change. Keeping the filter state as @State on a View would reset it every
// frame. Moving it into an ObservableObject scoped to the visualiser lets the
// filter integrate continuously while the rest of the UI redraws freely.
private final class OrientationFilter: ObservableObject {
    // Current orientation in degrees (canonical body-frame Euler angles).
    @Published var pitch: Double = 0
    @Published var roll:  Double = 0
    @Published var yaw:   Double = 0

    private var lastTimestamp: TimeInterval?

    // Complementary filter weight. 0.98 gyro / 0.02 accel. At the ~66 Hz
    // BLE packet rate that gives roughly a 0.7 s time constant — drift
    // from gyro integration gets corrected by gravity within ~2 seconds,
    // while the 3D model still tracks fast rotations smoothly.
    private let alpha: Double = 0.98

    // Gyro noise deadband (°/s). Below this we treat the reading as 0 so
    // we don't slowly integrate sensor bias into visible yaw drift when
    // the controller is sitting still.
    private let gyroDeadband: Double = 1.2

    func reset() {
        pitch = 0
        roll = 0
        yaw = 0
        lastTimestamp = nil
    }

    func update(sample: IMUSample) {
        let now = CACurrentMediaTime()
        let dt: Double
        if let last = lastTimestamp {
            dt = min(0.1, max(0.0, now - last))
        } else {
            dt = 0.0
        }
        lastTimestamp = now

        let gx = abs(sample.gyro.x) < gyroDeadband ? 0 : sample.gyro.x
        let gy = abs(sample.gyro.y) < gyroDeadband ? 0 : sample.gyro.y
        let gz = abs(sample.gyro.z) < gyroDeadband ? 0 : sample.gyro.z

        // Display convention: raw X/Y are preserved, but the grip's
        // upright/forward tilt is presented as pitch instead of roll.
        let gyroPitch = pitch + gx * dt
        let gyroRoll  = roll  + gy * dt
        let gyroYaw   = yaw   + gz * dt

        // Long-term pitch/roll: derive from gravity. Skip if the controller
        // is in free-fall or being shaken hard (|a| ≈ 0 or ≫ 1 G).
        let ax = sample.accel.x
        let ay = sample.accel.y
        let az = sample.accel.z
        let magnitude = sqrt(ax * ax + ay * ay + az * az)

        if magnitude > 0.6 && magnitude < 1.6 {
            let accPitch = atan2( ay, az) * 180.0 / .pi
            let accRoll  = atan2(-ax, sqrt(ay * ay + az * az)) * 180.0 / .pi

            // Wrap-safe complementary blend. Without the shortest-arc
            // correction, a reading like accRoll=+179° combined with
            // gyroRoll=-179° blends to 0°, snapping the model flat when
            // the user actually crossed the ±180 seam.
            pitch = blendAngles(gyroPitch, accPitch, alpha: alpha)
            roll  = blendAngles(gyroRoll,  accRoll,  alpha: alpha)
        } else {
            pitch = gyroPitch
            roll  = gyroRoll
        }
        yaw = normalizeAngle(gyroYaw)
    }

    private func normalizeAngle(_ deg: Double) -> Double {
        var a = deg.truncatingRemainder(dividingBy: 360.0)
        if a > 180 { a -= 360 }
        if a < -180 { a += 360 }
        return a
    }

    private func blendAngles(_ gyro: Double, _ accel: Double, alpha: Double) -> Double {
        // Shortest-arc difference so the blend doesn't cross 0 the wrong way.
        var diff = accel - gyro
        while diff > 180  { diff -= 360 }
        while diff < -180 { diff += 360 }
        return normalizeAngle(gyro + (1.0 - alpha) * diff)
    }
}

// MARK: - Joy-Con 3D visualiser
//
// Draws a simple stylised Joy-Con grip that rotates with the fused IMU.
// We deliberately stay inside SwiftUI rotation3DEffect rather than pulling
// in SceneKit — the view needs to survive window-close teardown and the
// previous SceneKit experiment was the source of the earlier
// NSWindowTransformAnimation crash.
struct JoyConOrientationView: View {
    let sample: IMUSample?
    let sourceLabel: String

    @StateObject private var filter = OrientationFilter()

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Joy-Con silhouette. Rectangle with a circular rail-top —
                // enough shape that tilt/roll is unambiguous.
                JoyConShape()
                    .fill(
                        LinearGradient(
                            colors: [.blue, Color.blue.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        // Top-of-controller arrow so you can tell
                        // pitch-up from pitch-down at a glance.
                        VStack {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white.opacity(0.85))
                                .padding(.top, 10)
                            Spacer()
                        }
                    )
                    .frame(width: 110, height: 220)
                    .shadow(radius: 10)
                    // Rotation order: yaw (Z) around world-up, pitch (X)
                    // around world-east, roll (Y) around world-north. For
                    // a SwiftUI-space cube that faces the camera (+Z out
                    // of the screen), this maps naturally to the Joy-Con
                    // canonical frame.
                    .rotation3DEffect(.degrees(filter.yaw),
                                      axis: (x: 0, y: 0, z: 1))
                    .rotation3DEffect(.degrees(filter.pitch),
                                      axis: (x: 1, y: 0, z: 0))
                    .rotation3DEffect(.degrees(-filter.roll),
                                      axis: (x: 0, y: 1, z: 0))
                    // Disable implicit animations — values update at ~60 Hz
                    // and SwiftUI's default transaction would try to
                    // animate between every pair. The lingering animation
                    // objects were the cause of the earlier
                    // _NSWindowTransformAnimation crash.
                    .animation(nil, value: filter.pitch)
                    .animation(nil, value: filter.roll)
                    .animation(nil, value: filter.yaw)
            }
            .frame(height: 240)

            HStack(spacing: 16) {
                anglePill(label: "Pitch", value: filter.pitch, color: .red)
                anglePill(label: "Roll",  value: filter.roll,  color: .green)
                anglePill(label: "Yaw",   value: filter.yaw,   color: .blue)
                Spacer()
                Button {
                    filter.reset()
                } label: {
                    Label("Recenter", systemImage: "scope")
                }
                .controlSize(.small)
            }
            Text("Source: \(sourceLabel) · pitch and roll are gravity-locked, yaw drifts (no magnetometer)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .onChange(of: sample) { newSample in
            guard let s = newSample else { return }
            filter.update(sample: s)
        }
    }

    private func anglePill(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(String(format: "%+.0f°", value))
                .font(.caption).monospacedDigit().foregroundColor(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
    }
}

// Simple rounded rectangle with a tab on top — reads as a Joy-Con enough
// for orientation feedback without needing a 3D model asset.
private struct JoyConShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: 18, height: 18))
        return path
    }
}

#Preview {
    GyroView()
        .environmentObject(DaemonBridge.shared.controllerStore)
        .frame(width: 800, height: 600)
}
