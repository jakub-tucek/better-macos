#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Build also checks the vendored C/Swift integration and the app's UI.
bash Tests/swiftui-compatibility.sh
bash build.sh
bash Tests/packaging.sh
bash Tests/build.sh
source Scripts/clipboard-package.sh
clipboard_package_test debug
clipboard_package_build release
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 \
    -I "$CLIPBOARD_PACKAGE_MODULES" "$CLIPBOARD_PACKAGE_ARCHIVE" \
    -I Vendor/strafe/CStrafe/include -I MouseHID ClipboardModule.swift Tests/ClipboardTests.swift Tests/ClipboardPresentationTests.swift WindowPositions.swift WindowPositionsView.swift \
    MouseSystemBackend.swift MouseModule.swift Tests/MouseTests.swift AppDelegate.swift AppModules.swift BuiltinFeatures.swift HostTransactions.swift Tests/HostTransactionsTests.swift KeepAwakeModule.swift QuitGuard.swift MenuBarModule.swift SourceUpdates.swift SystemControlLifecycle.swift ScreenEdges.swift AnimationPreferences.swift DisplayController.swift DisplayTopology.swift DisplayArrangementEditor.swift DisplayRefreshGate.swift SafetyWatchdog.swift Dashboard.swift SpacesModule.swift CommandRunner.swift BluetoothModule.swift Tests/main.swift \
    StoredState.swift UISurfaces.swift SetupWizard.swift Tests/UITests.swift Tests/StoredStateTests.swift AudioModule.swift Tests/AudioTests.swift Vendor/strafe/Swift/*.swift build/objects/CStrafe.o build/objects/IOHIDPayload.o build/objects/MouseHID.o \
    -framework AppKit -framework ServiceManagement -framework SwiftUI -framework CoreBluetooth -framework ApplicationServices -framework CoreGraphics \
    -framework Carbon -framework CoreAudio -framework CoreFoundation -framework IOKit -o build/isolated-tests
build/isolated-tests
bash Tests/install.sh
