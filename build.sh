#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/Monitor Toggle.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
xcrun swiftc -swift-version 5 -warnings-as-errors -O -target arm64-apple-macos13.0 \
    DisplayController.swift main.swift -framework AppKit -framework ServiceManagement \
    -o "$APP/Contents/MacOS/MonitorToggle"
codesign --force --sign - "$APP"
echo "Built: $APP"
