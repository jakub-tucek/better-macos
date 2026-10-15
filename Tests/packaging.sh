#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Inspect the real build, not a fixture: exact comparisons preserve every notice.
APP="$PWD/build/Fix macOS.app"
NOTICES="$APP/Contents/Resources/Licenses"
cmp LICENSE "$NOTICES/Fix-macOS-MIT.txt"
cmp Vendor/strafe/LICENSE "$NOTICES/strafe-LICENSE.txt"
cmp Vendor/strafe/UPSTREAM.txt "$NOTICES/strafe-UPSTREAM.txt"
grep -q 'Copyright (c) 2026 joshuarli' "$NOTICES/strafe-LICENSE.txt"
grep -q 'PERFORMANCE OF THIS SOFTWARE.' "$NOTICES/strafe-LICENSE.txt"
codesign --verify --strict "$APP"
echo 'PASS: real signed bundle contains complete project and third-party notices'
[[ "$(xcrun lipo -archs "$APP/Contents/MacOS/fix-mac-os")" == arm64 ]]
DEPENDENCIES="$(xcrun otool -L "$APP/Contents/MacOS/fix-mac-os")"
[[ "$DEPENDENCIES" != *ClipboardPolicy* && "$DEPENDENCIES" != *Testing.framework* ]]
ROOT="$(mktemp -d "$PWD/build/.relocated-package-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
ditto "$APP" "$ROOT/Relocated Fix macOS.app"
codesign --verify --strict "$ROOT/Relocated Fix macOS.app"
cmp "$APP/Contents/Info.plist" "$ROOT/Relocated Fix macOS.app/Contents/Info.plist"
cmp "$APP/Contents/Resources/Licenses/Fix-macOS-MIT.txt" "$ROOT/Relocated Fix macOS.app/Contents/Resources/Licenses/Fix-macOS-MIT.txt"
cmp "$APP/Contents/Resources/Licenses/strafe-LICENSE.txt" "$ROOT/Relocated Fix macOS.app/Contents/Resources/Licenses/strafe-LICENSE.txt"
cmp "$APP/Contents/Resources/Licenses/strafe-UPSTREAM.txt" "$ROOT/Relocated Fix macOS.app/Contents/Resources/Licenses/strafe-UPSTREAM.txt"
echo 'PASS: arm64 app has no dynamic policy/Testing dependency; relocated bundle retains signature, metadata and notices (not launched)'
