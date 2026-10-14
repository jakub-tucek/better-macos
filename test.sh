#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Build also checks the vendored C/Swift integration and the app's UI.
bash build.sh
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 \
    -I Vendor/strafe/CStrafe/include \
    AppDelegate.swift AppModules.swift SourceUpdates.swift SystemControlLifecycle.swift ScreenEdges.swift AnimationPreferences.swift DisplayController.swift DisplayTopology.swift DisplayArrangementEditor.swift DisplayRefreshGate.swift SafetyWatchdog.swift Dashboard.swift SpacesModule.swift CommandRunner.swift BluetoothModule.swift Tests/main.swift \
    Vendor/strafe/Swift/*.swift build/objects/*.o \
    -framework AppKit -framework ServiceManagement -framework SwiftUI -framework CoreBluetooth -framework ApplicationServices -framework CoreGraphics \
    -framework CoreFoundation -framework IOKit -o build/isolated-tests
build/isolated-tests
bash Tests/install.sh
