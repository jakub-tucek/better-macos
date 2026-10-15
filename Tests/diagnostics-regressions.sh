#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fixmacos-diagnostic-regressions.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 \
    Sources/Core/Diagnostics.swift Tests/DiagnosticsRegressions/main.swift -o "$ROOT/tests"
"$ROOT/tests"
if grep -E 'flushForTesting|queue\.sync' Sources/App/main.swift Sources/App/SafetyWatchdog.swift; then
    echo 'FAIL: safety entry must never await diagnostic delivery' >&2
    exit 1
fi
echo 'PASS: safety helper/watchdog entries contain no diagnostic flush or synchronous queue wait'
