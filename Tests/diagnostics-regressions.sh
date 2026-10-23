#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bettermacos-diagnostic-regressions.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 \
    Sources/Core/Diagnostics.swift Sources/Core/HostTransactions.swift Tests/DiagnosticsRegressions/Retention.swift Tests/DiagnosticsRegressions/Levels.swift Tests/DiagnosticsRegressions/main.swift -o "$ROOT/tests"
"$ROOT/tests"
if grep -E 'flushForTesting|queue\.sync' Sources/App/main.swift Sources/App/SafetyWatchdog.swift; then
    echo 'FAIL: safety entry must never await diagnostic delivery' >&2
    exit 1
fi
if grep -R 'flushForTesting(' Sources --include='*.swift' | grep -v 'func flushForTesting('; then
    echo 'FAIL: production must never call diagnostic test flush' >&2
    exit 1
fi
if grep 'queue\.sync' Sources/Core/Diagnostics.swift; then
    echo 'FAIL: diagnostic delivery must never synchronously await its worker' >&2
    exit 1
fi
echo 'PASS: safety helper/watchdog entries contain no diagnostic flush or synchronous queue wait'
