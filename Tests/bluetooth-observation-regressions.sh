#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fixmacos-bluetooth-observation.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 \
    Sources/Core/Diagnostics.swift Sources/Core/CommandRunner.swift Sources/Core/ActivityJournal.swift \
    Sources/Features/Audio/AudioModule.swift Sources/Features/Bluetooth/BluetoothModule.swift \
    Sources/Features/Bluetooth/BluetoothObservation.swift Sources/Features/Bluetooth/BluetoothProfilerProcess.swift \
    Tests/BluetoothPermissionRegressions/Support.swift Tests/BluetoothObservationTests.swift Tests/BluetoothObservationRegressions/main.swift \
    -framework AppKit -framework CoreBluetooth -framework CoreAudio -o "$ROOT/tests"
python3 - "$ROOT/tests" "$@" <<'PY'
import subprocess
import sys
subprocess.run(sys.argv[1:], check=True, timeout=60)
PY
