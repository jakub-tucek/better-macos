#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Build also checks the vendored C/Swift integration and the app's UI.
bash Tests/swiftui-compatibility.sh
bash Tests/diagnostics-regressions.sh
bash Tests/diagnostics-reader.sh
bash Tests/gesture-terminal-proof.sh --instant-safety
bash Tests/bluetooth-permission-regressions.sh
bash Tests/bluetooth-observation-regressions.sh
python3 Tests/feature-index-test.py
bash build.sh
bash Tests/packaging.sh
bash Tests/build.sh
source Scripts/clipboard-package.sh
clipboard_package_test debug
clipboard_package_build release
source scripts/source-inputs.sh
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 \
    "${APP_SOURCES[@]}" "${TEST_SOURCES[@]}" Tests/main.swift Vendor/strafe/Swift/*.swift \
    -I "$CLIPBOARD_PACKAGE_MODULES" "$CLIPBOARD_PACKAGE_ARCHIVE" \
    -I Vendor/strafe/CStrafe/include -I MouseHID \
    build/objects/CStrafe.o build/objects/IOHIDPayload.o build/objects/MouseHID.o \
    -framework AppKit -framework ServiceManagement -framework SwiftUI -framework CoreBluetooth -framework ApplicationServices -framework CoreGraphics \
    -framework Carbon -framework CoreAudio -framework CoreFoundation -framework IOKit -o build/isolated-tests
build/isolated-tests
bash Tests/install.sh
