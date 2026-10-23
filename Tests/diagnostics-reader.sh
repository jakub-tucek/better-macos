#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bettermacos-diagnostic-reader.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 -D DIAGNOSTICS_READER_TESTS \
    scripts/diagnostics.swift Tests/DiagnosticsReader/main.swift -o "$ROOT/tests"
"$ROOT/tests"
