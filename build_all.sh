#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"

# Apple requires the dext filename to equal its CFBundleIdentifier. sysextd
# walks Contents/Library/SystemExtensions/ and pattern-matches the bundle id
# against the file name, not against the Info.plist. Mismatches fail
# activation with "Extension not found in App bundle" even if the bundle
# itself is fine.
DEXT_NAME="local.joycon2mac.driver.dext"
SYSTEM_EXTENSIONS_DIR="$ROOT_DIR/build/JoyCon2Mac.app/Contents/Library/SystemExtensions"
PREBUILT_DEXT="$ROOT_DIR/build/xcode/Release/$DEXT_NAME"
LEGACY_DEXT="$ROOT_DIR/build/xcode/Release/VirtualJoyConDriver.dext"

# Build the daemon + GUI first.
"$ROOT_DIR/build_gui.sh"

embed_dext() {
    local source="$1"
    if [ ! -d "$source" ]; then
        return 1
    fi
    if [ ! -d "$ROOT_DIR/build/JoyCon2Mac.app" ]; then
        return 1
    fi
    mkdir -p "$SYSTEM_EXTENSIONS_DIR"
    # Remove any previous naming variants so we never ship with two side-by-
    # side bundles that could confuse sysextd.
    /bin/rm -rf "$SYSTEM_EXTENSIONS_DIR/VirtualJoyConDriver.dext"
    /bin/rm -rf "$SYSTEM_EXTENSIONS_DIR/$DEXT_NAME"
    cp -R "$source" "$SYSTEM_EXTENSIONS_DIR/$DEXT_NAME"
    if [ "$SIGN_IDENTITY" = "-" ] && [ "${FORCE_ENTITLEMENTS:-0}" != "1" ]; then
        codesign -s "$SIGN_IDENTITY" -f --deep \
            "$ROOT_DIR/build/JoyCon2Mac.app" >/dev/null
    else
        codesign -s "$SIGN_IDENTITY" -f --deep --generate-entitlement-der \
            --entitlements "$ROOT_DIR/JoyCon2MacApp/JoyCon2Mac.entitlements" \
            "$ROOT_DIR/build/JoyCon2Mac.app" >/dev/null
    fi
}

# If we already have a pre-built dext around, embed it immediately so
# build_all.sh never leaves the .app without its dext.
if embed_dext "$PREBUILT_DEXT"; then
    echo "Embedded pre-built DriverKit extension in JoyCon2Mac.app/Contents/Library/SystemExtensions."
elif embed_dext "$LEGACY_DEXT"; then
    echo "Embedded legacy-named pre-built DriverKit extension (will be rebuilt under the correct name)."
fi

echo
echo "Attempting DriverKit build..."
if "$ROOT_DIR/build_driver.sh"; then
    echo "DriverKit extension built."
    # Clean out any stale copies in Resources/ from older builds.
    /bin/rm -rf "$ROOT_DIR/build/JoyCon2Mac.app/Contents/Resources/VirtualJoyConDriver.dext" 2>/dev/null || true
    if embed_dext "$PREBUILT_DEXT"; then
        echo "Embedded freshly-built DriverKit extension in JoyCon2Mac.app/Contents/Library/SystemExtensions."
    fi
else
    echo "DriverKit build failed. The daemon and GUI app are still built."
    echo "Check build/xcode logs for DriverKit/iig diagnostics."
    if [ -d "$SYSTEM_EXTENSIONS_DIR/$DEXT_NAME" ]; then
        echo "(The pre-built dext embedded above is still in the bundle.)"
    fi
fi
