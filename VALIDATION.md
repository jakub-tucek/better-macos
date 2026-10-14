# Upstream validation — 2026-10-14

## Space animation / strafe

Compared every vendored Swift implementation against `rileycx/strafe` commit
`37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7` (v0.1.2-era main). All four Swift
files match byte-for-byte. C sources and headers now match too, including the
new macOS 27 Mission Control layer-20 detection. The module map is local build glue.

Ran upstream `Tests/IOHIDPayloadTests.c` against **our vendored C sources** with
undefined-behavior sanitization. Payload, direction, and overlay tests passed.
These tests replace event posting and window enumeration; they do not swipe the
live desktop. Local tests additionally exercise gesture suppression, boundaries,
keyboard exclusion, and disabled-interceptor passthrough.

Our integration restores the saved activation choice after the watchdog is ready
and displays settle. Interception pauses during display reconfiguration without
erasing that choice; it stays paused for the session until explicitly re-enabled.
Upstream hotkeys and menu implementation are not included.

### Mission Control versus Space switching

The reported “Cmd + Up is still animated” action opens Mission Control, not a
horizontal Space transition. Upstream `SwipeInterceptor` filters for horizontal
Dock swipes, excludes keyboard events from its tap mask, and passes gestures
through while `strafe_is_expose_active()` is true. Its speed setting therefore
does not accelerate opening the Mission Control overview. Upstream's separate
hotkeys invoke the horizontal switching engine; they do not change this scope.
The UI now distinguishes these actions and links to macOS Reduce motion settings
for the overview. No global motion preference was changed by this investigation.

## Monitor management

`DisplayController.swift` is custom code using SkyLight's undocumented
`CGSConfigureDisplayEnabled`; no monitor-project revision or copied source is
identified in this repository. Consequently **monitor upstream parity is not
established**. Lunar's public `Display.swift` and `DisplayController.swift` at
`491ec140bf3f11d55fe5d6e72ae72cc4bcee25cf` were inspected as a reference, but do
not expose a matching implementation of that function to validate against.

Local coverage checks last-screen protection, mirrored-source/slave rejection,
target identity rejection, notification coalescing, and real watchdog termination
of disposable children. GUI transactions now use time-limited helper processes;
**Safely** mode restores unconfirmed disabling after 20 seconds while the GUI is
responsive. **Dangerously** (default) skips that countdown; both modes retain
last-usable-screen protection. Arrangement changes still require confirmation.
The independent watchdog attempts restoration after terminating a stalled parent.
After an unrelated app crash, recorded disabled screens require explicit recovery.

The rebuilt app has not yet completed a live monitor disable/restore or physical
trackpad-swipe acceptance test. Source parity is not evidence that the original
cursor-only freeze is fixed. No claim is made that killing the app can recover a
stalled WindowServer or graphics driver.

## Matched screen edges

Pure geometry tests cover the entire large-display bottom edge, negative desktop
coordinates, proportional return mapping, side edges, removed screens, inward
movement, and ambiguous multi-neighbor edges. The event tap only rewrites mouse
movement; drag events reset its tracking and pass through. Mapping pauses during
display changes and requires the watchdog, Accessibility access, and a valid
non-overlapping layout. A physical pointer-crossing acceptance test is still needed.

The initial implementation used Quartz's default warp suppression and a 120ms
crossing cooldown. After a reported pause, the cursor source now sets local input
suppression to zero and uses the destination inset instead of a timed cooldown.
A regression check fails with the default source and passes with zero suppression.
This checks configuration; physical input latency still needs user verification.
The same warp symptom and source-scoped fix are reported in
[Hammerspoon #3332](https://github.com/Hammerspoon/hammerspoon/issues/3332).
