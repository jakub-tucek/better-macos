#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/Mac Utils.app"
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
    -o "$APP/Contents/MacOS/MacUtils"
codesign --force --sign "${MAC_UTILS_SIGNING_IDENTITY:--}" "$APP"
if [[ -z "${MAC_UTILS_SIGNING_IDENTITY:-}" ]]; then
    echo "Ad-hoc signing: macOS Bluetooth access may need granting again after rebuilds."
fi
echo "Built: $APP"
