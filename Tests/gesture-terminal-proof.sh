#!/bin/bash
# Default C regression plus opt-in characterization of remaining Swift holes.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:---instant-safety}"
case "$MODE" in
    --instant-safety|--characterize|--require-safety) ;;
    *) echo "Usage: $0 [--instant-safety|--characterize|--require-safety]" >&2; exit 2 ;;
esac
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
TMPBASE="${GESTURE_PROOF_TMPDIR:-${TMPDIR:-/tmp}}"
OUT=$(mktemp -d "$TMPBASE/gesture-terminal-proof.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
FIXTURE="$PWD/Tests/GestureTerminalProof"
INCLUDE="$PWD/Vendor/strafe/CStrafe/include"
COMMON=(-arch arm64 -mmacosx-version-min=15.0 -Wall -Wextra -Werror -I "$INCLUDE")
xcrun clang "${COMMON[@]}" -include "$FIXTURE/offline.h" -c Vendor/strafe/CStrafe/CStrafe.c -o "$OUT/strafe.o"
xcrun clang "${COMMON[@]}" -include "$FIXTURE/offline.h" -c Vendor/strafe/CStrafe/IOHIDPayload.c -o "$OUT/payload.o"
xcrun clang "${COMMON[@]}" -c "$FIXTURE/offline.c" -o "$OUT/offline.o"
xcrun clang "${COMMON[@]}" "$FIXTURE/instant.c" "$OUT/strafe.o" "$OUT/payload.o" "$OUT/offline.o" \
    -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation -o "$OUT/instant"
# Both production C posting sites must bind to the fake, never the system poster.
if nm -u "$OUT/strafe.o" "$OUT/payload.o" | grep -Eq ' _CGEventPost$'; then
    echo "Unsafe fixture: production object references live posting" >&2
    exit 2
fi
"$OUT/instant"
if [[ "$MODE" == --instant-safety ]]; then exit 0; fi
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macosx15.0 -I "$INCLUDE" \
    Vendor/strafe/Swift/Preferences.swift Vendor/strafe/Swift/TransitionSpeed.swift Vendor/strafe/Swift/SwitchEngine.swift \
    Vendor/strafe/Swift/SwipeInterceptor.swift "$FIXTURE/main.swift" \
    "$OUT/strafe.o" "$OUT/payload.o" "$OUT/offline.o" \
    -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation -o "$OUT/queued-and-interceptor"
"$OUT/queued-and-interceptor" "$MODE"
