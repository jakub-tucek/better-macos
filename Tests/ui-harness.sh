#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:---run-tests}" in --run-tests|--interactive) ;; *) echo 'Usage: bash Tests/ui-harness.sh [--run-tests|--interactive]' >&2; exit 2 ;; esac
case "${2:---setup}" in --setup|--links) ;; *) echo 'Preview surface must be --setup or --links' >&2; exit 2 ;; esac
[[ $# -le 2 ]] || exit 2
# A local test host, not the installed app. No VM, TCC grant, hotkey registration,
# clipboard access or system mutation. Reuses the app's actual SwiftUI screens.
source Scripts/clipboard-package.sh
clipboard_package_build release
source scripts/source-inputs.sh
mkdir -p build/ui-harness/objects
for source in CStrafe IOHIDPayload; do
    xcrun clang -O2 -arch arm64 -mmacosx-version-min=15.0 -I Vendor/strafe/CStrafe/include \
        -c "Vendor/strafe/CStrafe/$source.c" -o "build/ui-harness/objects/$source.o"
done
xcrun clang -O2 -arch arm64 -mmacosx-version-min=15.0 -c MouseHID/MouseHID.c -o build/ui-harness/objects/MouseHID.o
APP='build/Better macOS UI Test Host.app'
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE "$APP/Contents/Resources/Licenses/Better-macOS-MIT.txt"
cp Vendor/strafe/LICENSE "$APP/Contents/Resources/Licenses/strafe-LICENSE.txt"
cp Vendor/strafe/UPSTREAM.txt "$APP/Contents/Resources/Licenses/strafe-UPSTREAM.txt"
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 \
    "${APP_SOURCES[@]}" Tests/UIHarness/main.swift Vendor/strafe/Swift/*.swift \
    -I "$CLIPBOARD_PACKAGE_MODULES" "$CLIPBOARD_PACKAGE_ARCHIVE" \
    -I Vendor/strafe/CStrafe/include -I MouseHID build/ui-harness/objects/*.o \
    -framework AppKit -framework ServiceManagement -framework SwiftUI -framework CoreBluetooth -framework ApplicationServices -framework CoreGraphics \
    -framework Carbon -framework CoreAudio -framework CoreFoundation -framework IOKit -o "$APP/Contents/MacOS/ui-test-host"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.jakub-tucek.better-macos.ui-test-host</string>
<key>CFBundleName</key><string>Better macOS UI Test Host</string>
<key>CFBundleExecutable</key><string>ui-test-host</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
codesign --force --sign "${BETTER_MACOS_SIGNING_IDENTITY:-$(git config --local --get bettermacos.signingIdentity || echo -)}" "$APP"
codesign --verify --strict "$APP"
"$APP/Contents/MacOS/ui-test-host" "${1:---run-tests}" "${2:---setup}"
