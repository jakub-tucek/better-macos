#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fix-macos-swiftui-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
# Inherit the caller's toolchain/SDK; never select a different developer directory.
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 \
    -module-cache-path "$ROOT/module-cache" -typecheck \
    StoredState.swift Tests/Fixtures/StoredStateCompiler.swift
echo 'PASS: selected toolchain compiles production SwiftUI state wrapper, bindings and initializers'
