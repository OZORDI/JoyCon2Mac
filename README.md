# JoyCon2Mac

JoyCon2Mac is a native macOS driver and companion app for Nintendo Switch 2 Joy-Cons. It connects to the Joy-Cons over Bluetooth Low Energy, then exposes virtual HID devices through a DriverKit system extension so macOS apps can see a real controller and mouse.

## Install First

### Important Security Requirement

This release includes a local, unverified DriverKit system extension:

```text
local.joycon2mac.driver
```

The extension is not notarized and is not distributed through Apple's normal DriverKit approval flow. On a stock Mac, macOS can block it even if the app launches.

For this current development release, install and testing require:

- SIP disabled
- AMFI disabled
- A Mac you are comfortable using for driver development

Do not treat this as a normal consumer install yet. Re-enable SIP/AMFI when you are done testing other software. A future production release should use proper signing, notarization, and Apple-granted DriverKit entitlements instead of this local development setup.

### Install From Release

Existing releases were signed with the restricted system-extension entitlement, so on a stock Mac (SIP enabled) they do not launch at all — macOS reports `The application "JoyCon2Mac" can't be opened`. Right-click → `Open` does not help; the process is killed before Gatekeeper is even involved. Pick one of the two paths below.

#### Path A: app only, stock Mac (no driver — telemetry, battery, and gyro views work; gamepad and mouse do not)

1. Download `JoyCon2Mac.app.zip` from the GitHub release and unzip it.
2. Move `JoyCon2Mac.app` to `/Applications`.
3. Strip the entitlement the release cannot use anyway:

   ```bash
   xattr -d com.apple.quarantine /Applications/JoyCon2Mac.app 2>/dev/null
   codesign -s - -f /Applications/JoyCon2Mac.app
   ```

4. Launch the app.

#### Path B: full functionality (driver development machine)

The DriverKit extension is unsigned, so macOS will only load it with driver-development protections lowered. Do this only on a Mac you are comfortable using for driver development.

1. Boot into Recovery (shut down, then hold the power button), open `Utilities -> Terminal`, and run:

   ```bash
   csrutil disable
   nvram boot-args="amfi_get_out_of_my_way=1"
   ```

   Reboot back into macOS.
2. Enable system-extension developer mode:

   ```bash
   systemextensionsctl developer on
   ```

3. Install `JoyCon2Mac.app` into `/Applications` (release zip as-is, or a local `FORCE_ENTITLEMENTS=1 ./build_all.sh` build).
4. Launch the app and approve the DriverKit extension in `System Settings -> Privacy & Security`.
5. If macOS asks for a restart, restart, then open JoyCon2Mac again.

#### Pairing

Hold `SYNC` on each Joy-Con until the LEDs flash, then let the app connect.

If the app opens but no controller or mouse appears in Chrome, SDL apps, or macOS, the system extension is not loaded — check `systemextensionsctl list` and the Path B prerequisites.

### Build And Install Locally

```bash
./build_all.sh
open build/JoyCon2Mac.app
```

`build_all.sh` builds the daemon, SwiftUI app, DriverKit extension, and embeds the `.dext` into the app bundle at:

```text
build/JoyCon2Mac.app/Contents/Library/SystemExtensions/
```

Building requires full Xcode (the DriverKit SDK is not part of the Command Line Tools). If only a beta Xcode is installed, point the build at it:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./build_all.sh
```

### Signing Modes

Without `CODE_SIGN_IDENTITY`, builds are ad-hoc signed **without** the restricted `com.apple.developer.system-extension.install` entitlement — macOS kills ad-hoc apps that carry it at launch ("The application \"JoyCon2Mac\" can't be opened"), which is also why older releases refused to start on stock Macs. Such builds launch anywhere, but cannot activate the DriverKit extension, so only telemetry works.

To get the full driver on a SIP/AMFI-disabled development machine, keep the entitlement:

```bash
FORCE_ENTITLEMENTS=1 ./build_all.sh
```

With a real signing identity (`CODE_SIGN_IDENTITY=...`), entitlements are always embedded.

## What Works

### Gamepad

- Connects left and right Joy-Con 2 controllers over BLE.
- Exposes a virtual DualSense controller for Chrome, macOS GameController clients, SDL, RPCS3, Ryujinx, Game Pass, GeForce NOW, and other cloud gaming apps.
- Supports face buttons, D-pad, shoulders, ZL/ZR, sticks, stick clicks, Plus/Minus, Home, Capture, Chat/C, and rail buttons.
- Routes DualSense rumble output back to both Joy-Cons.
- Provides `SDL Only Mode`, which exposes only the DualSense-compatible HID path and hides the generic Joy-Con/mouse devices from strict clients. This fixes duplicate-controller and connect/disconnect churn in cloud apps.
- Keeps stable HID identity fields, including serials and nonzero location IDs, so apps are less likely to treat the virtual devices as hotplug churn.

### Mouse

- Uses the Joy-Con 2 optical sensor as a real relative HID mouse.
- Auto-picks whichever Joy-Con is resting on a surface.
- Lets one Joy-Con act as the mouse while the other remains part of the controller pair.
- Defaults mouse mode to `Normal`.
- Supports `Off`, `Slow`, `Normal`, and `Fast`.
- Uses HID mouse movement and HID wheel reports, so pointer and scroll input go through macOS mouse handling instead of Accessibility-only CGEvent injection.
- Suppresses mouse-owned buttons and stick input so they do not leak into the gamepad report.

### Haptics And Find My

- Parses DualSense rumble reports from apps and translates them into Joy-Con vibration packets.
- Supports left, right, and both Joy-Con rumble.
- Adds `Find Left`, `Find Right`, and `Find Both` controls.
- Find My uses a pulsing rumble pattern and stops per Joy-Con after about one second of deliberate shaking from that same Joy-Con's IMU.

### Motion

- Tracks accelerometer and gyroscope data per Joy-Con.
- Shows individual and fused IMU telemetry in the app.
- Displays a 3D orientation preview, pitch/roll/yaw values, and raw gyro/accelerometer values.
- Uses gravity for pitch/roll. Absolute yaw is gyro-only and will drift because Joy-Cons do not provide a magnetometer.

### Remapping

- Lets the four rail buttons be remapped:
  - Left SL
  - Left SR
  - Right SL
  - Right SR
- Bindings persist across restarts.

### App

- SwiftUI menu bar app.
- Controller connection cards with battery, RSSI, packet counters, and telemetry.
- Gamepad tester with live buttons/sticks, SDL mode, Find My controls, and rail remapping.
- Mouse page with mode, source, surface state, sensitivity, and button mapping.
- Gyro page with live motion visualization.
- Settings page for daemon control, driver state, and logs.

## Known Limitations

- The DriverKit extension is currently local/unverified and needs SIP plus AMFI disabled.
- NFC UI exists, but the backend is not finished.
- True macOS trackpad multitouch gestures are not implemented. Mouse mode is a HID mouse with wheel scrolling, not a virtual trackpad.
- Joy-Con yaw cannot be absolute without a magnetometer. It can be integrated while moving, but it will drift.
- Automatic wake/reconnect depends on the Joy-Con's stored pairing state and macOS BLE behavior. If a Joy-Con stops reconnecting from normal button presses, hold `SYNC` to re-enter pairing mode.

## Recommended Modes

Use `SDL Only Mode` for:

- GeForce NOW desktop app
- Game Pass/cloud gaming desktop apps
- RPCS3 SDL handler
- Ryujinx SDL input
- Any app that shows duplicate controllers or reconnect notifications

Leave `SDL Only Mode` off when you want:

- The generic Joy-Con HID visible for raw HID/browser experiments
- The virtual HID mouse visible at the same time as the virtual controller
- More debugging visibility in hardware tester sites

## Troubleshooting

### The App Opens But No Controller Appears

1. Confirm SIP and AMFI are disabled on the test Mac.
2. Open `System Settings -> Privacy & Security` and approve the system extension.
3. Restart if macOS asks.
4. Launch JoyCon2Mac again.
5. Check whether the extension is loaded:

```bash
systemextensionsctl list | grep joycon2mac
```

### Chrome Shows More Than One Controller

Turn on `SDL Only Mode` in Settings and restart the daemon from the app. Chrome can keep stale Gamepad API slots until the page is refreshed, so refresh the tester page after toggling.

### Cloud Gaming App Plays Connect/Disconnect Sounds

Enable `SDL Only Mode`. The cloud app should see only the DualSense-compatible virtual controller.

### Mouse Does Not Move

1. Make sure mouse mode is not `Off`.
2. Put one Joy-Con sensor-side down on a surface.
3. Confirm the Mouse page says that side is `on surface`.
4. Restart the daemon if the Joy-Cons were connected before changing modes.

### Rumble Does Not Work

Use an app that sends controller vibration through the DualSense output report path. If only one side vibrates, test with a game/action that emits both left and right motor commands; some games intentionally target one side.

### Pairing Gets Stuck

- Hold `SYNC` until the LEDs flash.
- Keep the Joy-Con close to the Mac.
- Remove stale Joy-Con entries from macOS Bluetooth settings if needed.
- Restart the JoyCon2Mac daemon from Settings.

## Build Requirements

- macOS 13 or newer
- Xcode with DriverKit support
- Xcode command line tools
- CMake 3.20 or newer
- Local driver-development machine with SIP/AMFI disabled for this unverified build

## Build Commands

```bash
# Full build: daemon, app, driver, embedded system extension
./build_all.sh

# App and daemon only
./build_gui.sh

# DriverKit extension only
./build_driver.sh
```

## Project Layout

```text
joycon2-mac-driver/
├── README.md
├── CMakeLists.txt
├── build_all.sh
├── build_gui.sh
├── build_driver.sh
├── JoyCon2Mac/
│   ├── main.mm
│   ├── BLEManager.h/mm
│   ├── PairingManager.h/mm
│   ├── JoyConDecoder.h/cpp
│   ├── MouseEmitter.h/mm
│   └── DriverKitClient.h/mm
├── JoyCon2MacApp/
│   ├── JoyCon2MacApp.swift
│   ├── DaemonBridge.swift
│   ├── ControllersView.swift
│   ├── GamepadView.swift
│   ├── MouseView.swift
│   ├── GyroView.swift
│   ├── NFCView.swift
│   ├── SettingsView.swift
│   ├── DriverExtensionInstaller.swift
│   └── LiquidGlassSupport.swift
└── VirtualJoyConDriver/
    ├── VirtualJoyConDriver.iig
    ├── VirtualJoyConDriver.cpp
    └── Info.plist
```

## Architecture

JoyCon2Mac has three pieces:

1. `JoyCon2Mac.app`: SwiftUI app, menu bar UI, telemetry, settings, and system extension activation.
2. `joycon2mac`: native daemon that owns BLE, decodes Joy-Con packets, handles haptics, pairing, mouse mode, and telemetry.
3. `local.joycon2mac.driver.dext`: DriverKit extension that publishes virtual HID devices and receives reports from the daemon.

The app talks to the daemon through JSON control and telemetry files. The daemon talks to the DriverKit extension through an IOKit user client.

## Development Notes

- Keep the virtual DualSense path stable. SDL/cloud apps depend on the Sony VID/PID, report shape, stable serial, and stable location ID.
- Keep `SDL Only Mode` as the compatibility path for strict clients.
- Do not reintroduce CGEvent-based mouse or gesture output for core mouse behavior. HID mouse reports work without Accessibility permissions.
- The generic Joy-Con HID path is useful for experiments, but it can confuse apps that expect only one controller.

## License

MIT. See `LICENSE`.
