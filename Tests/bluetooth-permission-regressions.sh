#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fixmacos-bluetooth-permission.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 \
    Sources/Core/Diagnostics.swift Sources/Core/CommandRunner.swift Sources/Core/ActivityJournal.swift \
    Sources/Features/Audio/AudioModule.swift Sources/Features/Bluetooth/BluetoothModule.swift \
    Sources/Features/Bluetooth/BluetoothCycleDelivery.swift \
    Sources/Features/Bluetooth/BluetoothObservation.swift Sources/Features/Bluetooth/BluetoothProfilerProcess.swift \
    Tests/BluetoothPermissionRegressions/Support.swift Tests/BluetoothPermissionRegressions/main.swift \
    -framework AppKit -framework CoreBluetooth -framework CoreAudio -o "$ROOT/tests"
# External deadline affects only this fixture process and its self-expiring helper.
python3 - "$ROOT/tests" <<'PY'
import subprocess
import sys
subprocess.run([sys.argv[1]], check=True, timeout=30)
PY
