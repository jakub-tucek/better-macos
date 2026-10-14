#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/Fix macOS.app"
# Local repository configuration keeps permission identity stable across builds.
# An unavailable configured certificate must fail signing, never fall back silently.
SIGNING_IDENTITY="${MAC_UTILS_SIGNING_IDENTITY:-$(git config --local --get macutils.signingIdentity || true)}"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
REVISION="$(git rev-parse HEAD)"
plutil -insert FixMacOSRevision -string "$REVISION" "$APP/Contents/Info.plist"
if [[ "${FIX_MACOS_SOURCE_INSTALL:-0}" == 1 ]]; then
    plutil -insert FixMacOSSourceInstall -bool YES "$APP/Contents/Info.plist"
    plutil -insert FixMacOSSourceDirectory -string "$PWD" "$APP/Contents/Info.plist"
    plutil -insert FixMacOSInstallDestination -string "$FIX_MACOS_INSTALL_DESTINATION" "$APP/Contents/Info.plist"
fi
mkdir -p build/objects
for source in CStrafe IOHIDPayload; do
    xcrun clang -O2 -arch arm64 -mmacosx-version-min=15.0 \
        -I Vendor/strafe/CStrafe/include -c "Vendor/strafe/CStrafe/$source.c" \
        -o "build/objects/$source.o"
done
xcrun swiftc -swift-version 5 -warnings-as-errors -O -target arm64-apple-macos15.0 \
    -I Vendor/strafe/CStrafe/include \
    AppModules.swift DisplayController.swift DisplayTopology.swift DisplayArrangementEditor.swift DisplayRefreshGate.swift SafetyWatchdog.swift Dashboard.swift AppDelegate.swift CommandRunner.swift BluetoothModule.swift \
    SourceUpdates.swift SystemControlLifecycle.swift ScreenEdges.swift AnimationPreferences.swift SpacesModule.swift Vendor/strafe/Swift/*.swift main.swift \
    build/objects/*.o -framework AppKit -framework ServiceManagement \
    -framework SwiftUI -framework CoreBluetooth -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation -framework IOKit \
    -o "$APP/Contents/MacOS/fix-mac-os"
codesign --force --sign "${SIGNING_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Ad-hoc signing: Accessibility and Bluetooth access may need granting again after rebuilds."
fi
echo "Built: $APP"
