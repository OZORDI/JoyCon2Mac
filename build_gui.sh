#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/build/JoyCon2Mac.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DAEMON="$ROOT_DIR/build/bin/joycon2mac"
HELPER_APP="$RESOURCES_DIR/JoyCon2MacDaemon.app"
HELPER_CONTENTS="$HELPER_APP/Contents"
HELPER_MACOS="$HELPER_CONTENTS/MacOS"
APP_ENTITLEMENTS="$ROOT_DIR/JoyCon2MacApp/JoyCon2Mac.entitlements"

SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
APP_PROVISIONING_PROFILE="${APP_PROVISIONING_PROFILE:-}"
echo "Using code signing identity: $SIGN_IDENTITY"

if [ -n "$APP_PROVISIONING_PROFILE" ] && [ "$SIGN_IDENTITY" = "-" ]; then
    echo "APP_PROVISIONING_PROFILE requires CODE_SIGN_IDENTITY to be set." >&2
    exit 1
fi

echo "Building JoyCon2Mac daemon..."
cmake -S "$ROOT_DIR" -B "$ROOT_DIR/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$ROOT_DIR/build" --target joycon2mac --config Release --parallel "$(sysctl -n hw.ncpu)"

if [ ! -x "$DAEMON" ]; then
    echo "Expected daemon not found at $DAEMON" >&2
    exit 1
fi

echo "Building JoyCon2Mac.app..."
/bin/rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPER_MACOS"
cp "$ROOT_DIR/JoyCon2MacApp/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$DAEMON" "$HELPER_MACOS/joycon2mac"
if [ -n "$APP_PROVISIONING_PROFILE" ]; then
    cp "$APP_PROVISIONING_PROFILE" "$CONTENTS_DIR/embedded.provisionprofile"
fi
cat > "$HELPER_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>joycon2mac</string>
    <key>CFBundleIdentifier</key>
    <string>local.joycon2mac.daemon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>JoyCon2MacDaemon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>2026.05.05</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>JoyCon2MacDaemon connects to Nintendo Switch 2 Joy-Con controllers over Bluetooth.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>JoyCon2MacDaemon connects to Nintendo Switch 2 Joy-Con controllers over Bluetooth.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

swiftc \
    -target arm64-apple-macosx13.0 \
    -O \
    -framework SwiftUI \
    -framework AppKit \
    -framework Combine \
    -framework SystemExtensions \
    -framework UniformTypeIdentifiers \
    "$ROOT_DIR"/JoyCon2MacApp/*.swift \
    -o "$MACOS_DIR/JoyCon2Mac"

codesign -s "$SIGN_IDENTITY" -f "$HELPER_APP" >/dev/null
if [ "$SIGN_IDENTITY" = "-" ] && [ "${FORCE_ENTITLEMENTS:-0}" != "1" ]; then
    echo "Ad-hoc signing: omitting restricted entitlements (set FORCE_ENTITLEMENTS=1 for SIP/AMFI-disabled dev machines)."
    codesign -s "$SIGN_IDENTITY" -f --deep "$APP_DIR" >/dev/null
else
    codesign -s "$SIGN_IDENTITY" -f --deep --generate-entitlement-der --entitlements "$APP_ENTITLEMENTS" "$APP_DIR" >/dev/null
fi

echo "Built: $APP_DIR"
