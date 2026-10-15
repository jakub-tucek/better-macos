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
