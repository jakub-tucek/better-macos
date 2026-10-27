#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
OUTPUT="$PWD/build/Better macOS.app"
# Shared per-Mac/repository configuration selects a repeatable signing identity.
# An unavailable configured certificate must fail signing, never fall back silently.
SIGNING_IDENTITY="$(python3 scripts/signing.py resolve)"
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
cp LICENSE "$APP/Contents/Resources/Licenses/Better-macOS-MIT.txt"
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
plutil -insert BetterMacOSRevision -string "$REVISION" "$APP/Contents/Info.plist"
plutil -insert BetterMacOSDeploymentProtocol -integer 1 "$APP/Contents/Info.plist"
if [[ "${BETTER_MACOS_SOURCE_INSTALL:-0}" == 1 ]]; then
    plutil -insert BetterMacOSSourceInstall -bool YES "$APP/Contents/Info.plist"
    plutil -insert BetterMacOSSourceDirectory -string "$PWD" "$APP/Contents/Info.plist"
    plutil -insert BetterMacOSInstallDestination -string "$BETTER_MACOS_INSTALL_DESTINATION" "$APP/Contents/Info.plist"
    if [[ "${BETTER_MACOS_LOCAL_DEVELOPMENT:-0}" == 1 ]]; then
        plutil -insert BetterMacOSLocalDevelopment -bool YES "$APP/Contents/Info.plist"
    fi
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
source scripts/source-inputs.sh
xcrun swiftc -swift-version 5 -warnings-as-errors -O -target arm64-apple-macos15.0 \
    "${APP_SOURCES[@]}" "$STAGE/DiagnosticBuild.swift" Sources/App/main.swift Vendor/strafe/Swift/*.swift \
    -I "$CLIPBOARD_PACKAGE_MODULES" "$CLIPBOARD_PACKAGE_ARCHIVE" \
    -I Vendor/strafe/CStrafe/include -I MouseHID \
    build/objects/CStrafe.o build/objects/IOHIDPayload.o build/objects/MouseHID.o \
    -framework Carbon -framework CoreAudio -framework AppKit -framework ServiceManagement \
    -framework SwiftUI -framework CoreBluetooth -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation -framework IOKit \
    -o "$APP/Contents/MacOS/better-macos"
codesign --force --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --strict "$APP"
if [[ -e "$OUTPUT" ]]; then mv "$OUTPUT" "$STAGE/previous.app"; fi
mv "$APP" "$OUTPUT"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Ad-hoc signing: Accessibility and Bluetooth access may need granting again after rebuilds."
fi
echo "Built: $OUTPUT"
