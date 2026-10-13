#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Build also checks the vendored C/Swift integration and the app's UI.
bash build.sh
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 \
    -I Vendor/strafe/CStrafe/include \
    DisplayController.swift MonitorRow.swift CommandRunner.swift BluetoothModule.swift Tests/main.swift \
    Vendor/strafe/Swift/*.swift build/objects/*.o \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics \
    -framework CoreFoundation -framework IOKit -o build/isolated-tests
build/isolated-tests
