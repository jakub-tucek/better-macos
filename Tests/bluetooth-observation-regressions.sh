#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bettermacos-bluetooth-observation.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 \
    Sources/Core/Diagnostics.swift Sources/Core/CommandRunner.swift Sources/Core/ActivityJournal.swift \
    Sources/Features/Audio/AudioModule.swift Sources/Features/Bluetooth/BluetoothModule.swift \
    Sources/Features/Bluetooth/BluetoothCycleDelivery.swift \
    Sources/Features/Bluetooth/BluetoothObservation.swift Sources/Features/Bluetooth/BluetoothProfilerProcess.swift Sources/App/BluetoothReadOnlyProbe.swift \
    Tests/BluetoothPermissionRegressions/Support.swift Tests/BluetoothObservationTests.swift Tests/BluetoothObservationRegressions/main.swift \
    -framework AppKit -framework CoreBluetooth -framework CoreAudio -o "$ROOT/tests"
python3 - "$ROOT/tests" "$@" <<'PY'
import subprocess
import sys
from pathlib import Path

entry = Path("Sources/App/main.swift").read_text()
assert entry.index("if launchMode == .bluetoothReadOnlyProbe") < entry.index('firstIndex(of: "--watchdog")')
assert 'mode.delegate(normal: { AppDelegate() }, probe: { BluetoothReadOnlyProbeDelegate() })' in entry
probe = Path("Sources/App/BluetoothReadOnlyProbe.swift").read_text()
for forbidden in [".openConnection(", ".closeConnection(", ".register(", ".unregister(", ".scanForPeripherals(",
                  ".set(", "BluetoothModule(", "AudioModule(", "DisplayController(", "CBCentralManager(",
                  "HostTransactions(", "SafetySupervisor(", "SystemLoginService(", "CommandRunner("]:
    assert forbidden not in probe, forbidden
print("PASS: explicit probe entry precedes command dispatch and exposes no mutation or normal-host capabilities", flush=True)
subprocess.run(sys.argv[1:], check=True, timeout=60)
PY
