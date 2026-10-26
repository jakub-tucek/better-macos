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
bash build.sh
bash Tests/packaging.sh
bash Tests/build.sh
source Scripts/clipboard-package.sh
clipboard_package_test debug
clipboard_package_build release
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 \
    Sources/Features/Bluetooth/BluetoothCycleDelivery.swift Tests/BluetoothCycleDeliveryTests.swift \
    Sources/Core/ActivityJournal.swift Sources/SharedUI/ActivityView.swift Tests/ActivityTests.swift Tests/ActivityScrollTests.swift Tests/PresentationDisplayRefreshTests.swift \
    Sources/Core/Diagnostics.swift Sources/Core/LoginDiagnostics.swift Tests/DiagnosticsTests.swift \
    Sources/Features/Bluetooth/BluetoothObservation.swift Sources/Features/Bluetooth/BluetoothProfilerProcess.swift Sources/App/BluetoothReadOnlyProbe.swift Tests/BluetoothObservationTests.swift \
    Sources/App/LoginService.swift Tests/LoginServiceTests.swift Sources/Features/KeepAwake/KeepAwakeFeature.swift Sources/Features/KeepAwake/KeepAwakePresentation.swift Tests/KeepAwakeFeatureTests.swift \
    Sources/SharedUI/ActionPalette.swift Sources/Features/KeepAwake/KeepAwakePalette.swift \
    Sources/SharedUI/AppStyle.swift \
    -I "$CLIPBOARD_PACKAGE_MODULES" "$CLIPBOARD_PACKAGE_ARCHIVE" \
    Sources/Features/Battery/BatteryModule.swift Tests/BatteryTests.swift \
    -I Vendor/strafe/CStrafe/include -I MouseHID Sources/SharedUI/StatusQuickMenu.swift Sources/Features/Clipboard/ClipboardModule.swift Sources/Features/Links/LinkRouting.swift Sources/Features/Links/LinksModule.swift Sources/Features/Links/LinksSettingsView.swift Tests/ClipboardTests.swift Tests/LinksTests.swift Tests/ClipboardPresentationTests.swift Sources/Features/Windows/WindowShortcuts.swift Sources/Features/Windows/WindowShortcutSession.swift Tests/WindowShortcutTests.swift Sources/Features/Windows/WindowPositions.swift Sources/Features/Windows/WindowExecution.swift Sources/Features/Windows/AXWindowNativeAccess.swift Tests/WindowExecutionTests.swift Sources/Features/Windows/WindowPositionsView.swift Sources/Features/Windows/WindowActionPalette.swift \
    Sources/Features/Mouse/MouseSystemBackend.swift Sources/Features/Mouse/MouseModule.swift Tests/MouseTests.swift Sources/App/AppDelegate.swift Sources/App/AppModules.swift Sources/App/BuiltinFeatures.swift Sources/App/BuiltinChoicePreparations.swift Sources/Core/HostTransactions.swift Tests/HostTransactionsTests.swift Sources/Features/KeepAwake/KeepAwakeModule.swift Sources/Features/QuitGuard/QuitGuard.swift Sources/Features/MenuBar/MenuBarModule.swift Sources/App/SourceUpdates.swift Sources/Core/SystemControlLifecycle.swift Sources/Features/Displays/ScreenEdges.swift Sources/Features/Animations/AnimationPreferences.swift Sources/Features/Displays/DisplayController.swift Sources/Features/Displays/DisplayTopology.swift Sources/Features/Displays/DisplayArrangementEditor.swift Sources/Features/Displays/DisplayRefreshGate.swift Sources/App/SafetyWatchdog.swift Sources/SharedUI/Dashboard.swift Sources/Features/Animations/SpacesModule.swift Sources/Core/CommandRunner.swift Sources/Features/Bluetooth/BluetoothModule.swift Tests/main.swift \
    Sources/SharedUI/StoredState.swift Sources/SharedUI/UISurfaces.swift Sources/App/SetupWizard.swift Tests/UITests.swift Tests/BluetoothErrorRecoveryTests.swift Tests/StoredStateTests.swift Sources/Features/Audio/AudioModule.swift Tests/AudioTests.swift Vendor/strafe/Swift/*.swift build/objects/CStrafe.o build/objects/IOHIDPayload.o build/objects/MouseHID.o \
    -framework AppKit -framework ServiceManagement -framework SwiftUI -framework CoreBluetooth -framework ApplicationServices -framework CoreGraphics \
    -framework Carbon -framework CoreAudio -framework CoreFoundation -framework IOKit -o build/isolated-tests
build/isolated-tests
bash Tests/install.sh
