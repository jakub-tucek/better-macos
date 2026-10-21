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
[[ "$REVISION" =~ ^[a-f0-9]{40}$ ]] || { echo "Invalid build revision" >&2; exit 1; }
echo "let compiledDiagnosticRevision = \"$REVISION\"" > "$STAGE/DiagnosticBuild.swift"
SOURCE_STATE=unknown
if SOURCE_STATUS="$(git status --porcelain --untracked-files=normal -- Sources MouseHID Vendor Package.swift build.sh Scripts Info.plist)"; then
    SOURCE_STATE=clean
    if [[ -n "$SOURCE_STATUS" ]]; then SOURCE_STATE=modified; fi
fi
echo "let compiledDiagnosticSourceState = \"$SOURCE_STATE\"" >> "$STAGE/DiagnosticBuild.swift"
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
    Sources/Core/ActivityJournal.swift Sources/SharedUI/ActivityView.swift \
    Sources/Core/Diagnostics.swift Sources/Core/LoginDiagnostics.swift "$STAGE/DiagnosticBuild.swift" \
    Sources/App/LoginService.swift Sources/Features/KeepAwake/KeepAwakeFeature.swift Sources/Features/KeepAwake/KeepAwakePresentation.swift \
    -I "$CLIPBOARD_PACKAGE_MODULES" "$CLIPBOARD_PACKAGE_ARCHIVE" \
    -I Vendor/strafe/CStrafe/include -I MouseHID Sources/Features/Clipboard/ClipboardModule.swift Sources/Features/Windows/WindowShortcuts.swift Sources/Features/Windows/WindowPositions.swift Sources/Features/Windows/WindowPositionsView.swift \
    Sources/App/AppModules.swift Sources/App/BuiltinFeatures.swift Sources/App/BuiltinChoicePreparations.swift Sources/Core/HostTransactions.swift Sources/Features/Displays/DisplayController.swift Sources/Features/Displays/DisplayTopology.swift Sources/Features/Displays/DisplayArrangementEditor.swift Sources/Features/Displays/DisplayRefreshGate.swift Sources/App/SafetyWatchdog.swift Sources/SharedUI/Dashboard.swift Sources/App/AppDelegate.swift Sources/Core/CommandRunner.swift Sources/Features/Bluetooth/BluetoothModule.swift \
    Sources/Features/Bluetooth/BluetoothObservation.swift Sources/Features/Bluetooth/BluetoothProfilerProcess.swift Sources/App/BluetoothReadOnlyProbe.swift \
    Sources/Features/Mouse/MouseSystemBackend.swift Sources/Features/Mouse/MouseModule.swift Sources/Features/KeepAwake/KeepAwakeModule.swift Sources/Features/QuitGuard/QuitGuard.swift Sources/Features/MenuBar/MenuBarModule.swift Sources/App/SourceUpdates.swift Sources/Core/SystemControlLifecycle.swift Sources/Features/Displays/ScreenEdges.swift Sources/Features/Animations/AnimationPreferences.swift Sources/Features/Animations/SpacesModule.swift Vendor/strafe/Swift/*.swift Sources/App/main.swift \
    Sources/SharedUI/StoredState.swift Sources/SharedUI/UISurfaces.swift Sources/App/SetupWizard.swift Sources/Features/Audio/AudioModule.swift build/objects/CStrafe.o build/objects/IOHIDPayload.o build/objects/MouseHID.o -framework Carbon -framework CoreAudio -framework AppKit -framework ServiceManagement \
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
