#!/bin/bash
# Hidden native viewport fixture only; never launches the production app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
STAGE="$(mktemp -d "$ROOT/build/.activity-scroll.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cat > "$STAGE/Probe.swift" <<'SWIFT'
import AppKit
import SwiftUI

private var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1; print("PASS: \(message)")
}

@main struct ActivityScrollRegressions {
    static func main() {
        _ = NSApplication.shared
        let journal = ActivityJournal()
        let presentation = ActivityPresentation(journal: journal)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ActivityView(presentation: presentation))
        runActivityScrollTests(journal: journal, window: window)
        print("\(checks) activity native scrolling regression checks passed")
        window.close()
    }
}
SWIFT
xcrun swiftc -swift-version 5 -warnings-as-errors -target arm64-apple-macos15.0 \
    Sources/Core/ActivityJournal.swift Sources/SharedUI/StoredState.swift \
    Sources/SharedUI/ActivityView.swift Tests/ActivityScrollTests.swift \
    "$STAGE/Probe.swift" -o "$STAGE/activity-scroll"
"$STAGE/activity-scroll"
