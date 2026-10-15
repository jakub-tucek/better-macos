#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
OUTPUT="$PWD/build/Fix macOS.app"
# Local repository configuration selects a repeatable signing identity across builds.
# An unavailable configured certificate must fail signing, never fall back silently.
SIGNING_IDENTITY="${MAC_UTILS_SIGNING_IDENTITY:-$(git config --local --get macutils.signingIdentity || true)}"
mkdir -p build
STAGE="$(mktemp -d "$PWD/build/.bundle.XXXXXX")"
cleanup() {
    local result=$?
    if [[ -d "$STAGE/previous.app" && ! -e "$OUTPUT" ]]; then
        mv "$STAGE/previous.app" "$OUTPUT" || echo "Previous build remains at $STAGE/previous.app" >&2
    fi
    # Only remove this invocation's staging directory; retain a failed rollback.
    if [[ ! -d "$STAGE/previous.app" || -d "$OUTPUT" ]]; then rm -rf "$STAGE"; fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
APP="$STAGE/new.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE "$APP/Contents/Resources/Licenses/Fix-macOS-MIT.txt"
cp Vendor/strafe/LICENSE "$APP/Contents/Resources/Licenses/strafe-LICENSE.txt"
cp Vendor/strafe/UPSTREAM.txt "$APP/Contents/Resources/Licenses/strafe-UPSTREAM.txt"
cp Info.plist "$APP/Contents/Info.plist"
REVISION="$(git rev-parse HEAD)"
plutil -insert FixMacOSRevision -string "$REVISION" "$APP/Contents/Info.plist"
if [[ "${FIX_MACOS_SOURCE_INSTALL:-0}" == 1 ]]; then
    plutil -insert FixMacOSSourceInstall -bool YES "$APP/Contents/Info.plist"
    plutil -insert FixMacOSSourceDirectory -string "$PWD" "$APP/Contents/Info.plist"
    plutil -insert FixMacOSInstallDestination -string "$FIX_MACOS_INSTALL_DESTINATION" "$APP/Contents/Info.plist"
fi
source Scripts/clipboard-package.sh
clipboard_package_build release
mkdir -p build/objects
for source in CStrafe IOHIDPayload; do
    xcrun clang -O2 -arch arm64 -mmacosx-version-min=15.0 \
        -I Vendor/strafe/CStrafe/include -c "Vendor/strafe/CStrafe/$source.c" \
        -o "build/objects/$source.o"
done
xcrun clang -O2 -arch arm64 -mmacosx-version-min=15.0 -c MouseHID/MouseHID.c -o build/objects/MouseHID.o
xcrun swiftc -swift-version 5 -warnings-as-errors -O -target arm64-apple-macos15.0 \
    -I "$CLIPBOARD_PACKAGE_MODULES" "$CLIPBOARD_PACKAGE_ARCHIVE" \
    -I Vendor/strafe/CStrafe/include -I MouseHID ClipboardModule.swift WindowPositions.swift WindowPositionsView.swift \
    AppModules.swift BuiltinFeatures.swift BuiltinChoicePreparations.swift HostTransactions.swift DisplayController.swift DisplayTopology.swift DisplayArrangementEditor.swift DisplayRefreshGate.swift SafetyWatchdog.swift Dashboard.swift AppDelegate.swift CommandRunner.swift BluetoothModule.swift \
    MouseSystemBackend.swift MouseModule.swift KeepAwakeModule.swift QuitGuard.swift MenuBarModule.swift SourceUpdates.swift SystemControlLifecycle.swift ScreenEdges.swift AnimationPreferences.swift SpacesModule.swift Vendor/strafe/Swift/*.swift main.swift \
    StoredState.swift UISurfaces.swift SetupWizard.swift AudioModule.swift build/objects/CStrafe.o build/objects/IOHIDPayload.o build/objects/MouseHID.o -framework Carbon -framework CoreAudio -framework AppKit -framework ServiceManagement \
    -framework SwiftUI -framework CoreBluetooth -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation -framework IOKit \
    -o "$APP/Contents/MacOS/fix-mac-os"
codesign --force --sign "${SIGNING_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
if [[ -e "$OUTPUT" ]]; then mv "$OUTPUT" "$STAGE/previous.app"; fi
mv "$APP" "$OUTPUT"
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Ad-hoc signing: Accessibility and Bluetooth access may need granting again after rebuilds."
fi
echo "Built: $OUTPUT"
