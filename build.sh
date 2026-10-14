#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/fix-mac-os.app"
# Local repository configuration keeps permission identity stable across builds.
# An unavailable configured certificate must fail signing, never fall back silently.
SIGNING_IDENTITY="${MAC_UTILS_SIGNING_IDENTITY:-$(git config --local --get macutils.signingIdentity || true)}"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p build/objects
for source in CStrafe IOHIDPayload; do
    xcrun clang -O2 -arch arm64 -mmacosx-version-min=15.0 \
        -I Vendor/strafe/CStrafe/include -c "Vendor/strafe/CStrafe/$source.c" \
        -o "build/objects/$source.o"
done
xcrun swiftc -swift-version 5 -warnings-as-errors -O -target arm64-apple-macos15.0 \
    -I Vendor/strafe/CStrafe/include \
    DisplayController.swift DisplayRefreshGate.swift SafetyWatchdog.swift Dashboard.swift AppDelegate.swift CommandRunner.swift BluetoothModule.swift \
    SpacesModule.swift Vendor/strafe/Swift/*.swift main.swift \
    build/objects/*.o -framework AppKit -framework ServiceManagement \
    -framework SwiftUI -framework CoreBluetooth -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation -framework IOKit \
    -o "$APP/Contents/MacOS/fix-mac-os"
codesign --force --sign "${SIGNING_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Ad-hoc signing: Accessibility and Bluetooth access may need granting again after rebuilds."
fi
echo "Built: $APP"
