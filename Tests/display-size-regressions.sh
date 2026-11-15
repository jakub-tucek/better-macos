#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bettermacos-display-size.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 \
    Sources/Features/Displays/DisplaySize.swift Tests/DisplaySizeRegressions/main.swift -o "$ROOT/tests"
"$ROOT/tests"
