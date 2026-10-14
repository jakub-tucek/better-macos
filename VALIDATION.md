# Upstream validation — 2026-10-14

## Space animation / strafe

Compared every vendored Swift implementation against `rileycx/strafe` commit
`37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7` (v0.1.2-era main). All four Swift
files matched byte-for-byte at import. SwitchEngine.swift now has a local queue
cancellation/draining patch and injectable phase posting for tests. C sources and
headers remain unchanged, including the
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

## Lifecycle regression coverage

The test executable now includes AppDelegate. Its real display-helper dispatch
path runs with an injected command runner and gesture sink: an active ramp must
post its terminal phase before the helper runs, while queued ramps are canceled.
SystemControlLifecycle drives both host cursor reconciliation and tests for
confirmation, stale snapshots, module disable, and watchdog loss. Repeated
watchdog status reports are deduplicated; recovery does not depend on readiness.

Animation updates persist a pending-recovery marker before writing system keys.
Failed apply/rollback is tested with injected failures, including restoration by
a fresh module instance while the preset is Off. Startup attempts pending recovery
even when the parent module is disabled, and the UI provides a retry action.
Bluetooth takeover tests cover shutdown during both success and failure, ensuring
the stop completion runs once and automation remains disabled.
# Menu-bar controls

The menu-bar module uses AppKit status items for a movable, expandable divider.
It does not enumerate, capture, or reposition other applications' icons. Hiding
requires the chevron to be right of the divider; invalid placement is rejected.
Hidden state is session-only, and removing the module's items reveals the icons.
Very crowded/notched menu bars may not have room to reveal every icon.
An isolated live AppKit probe on this Mac confirmed divider expansion, a stationary
chevron on the three external menu bars, reveal, and removal. User-arranged icon
sets and notched-screen overflow still need hands-on validation.

Compact spacing writes the undocumented global `NSStatusItemSpacing` and
`NSStatusItemSelectionPadding` preferences. Their effect on Tahoe is not visually
verified; affected processes may cache them until relaunch or logout. No process
is killed to apply spacing. Isolated tests cover restoring original values and
absent keys, repeated enable, failed rollback, and recovery by a new owner.
# Hold to quit

The keyboard module intercepts plain Command-Q using a session event tap and
recognizes Q through the event's current keyboard layout. Its nonactivating HUD
names the captured foreground app. A monotonic countdown checks physical key
state and foreground identity before requesting normal application termination.
It never force-quits or replays a shortcut into a different app. Key repeats and
the matching key-up remain consumed after cancellation or completion.

Isolated state-machine checks cover short presses, repeats, early release,
foreground changes, cancellation, one quit per press, and both hold durations.
The Pac-Man countdown uses a display-driven SwiftUI timeline and the hold's
monotonic start time; input polling does not publish progress or restart animation.
Frame checks cover movement between 30 Hz input polls (including 120 Hz samples),
dot consumption, bounds, and the three-second default.
Actual keyboard-layout behavior, secure-input contexts, full-screen HUD placement,
and application-specific quit/save prompts require hands-on validation. When macOS
does not deliver events (for example, secure input), interception is not guaranteed.

## Audio 2A / 2B

- `bash test.sh` passes: 251 isolated checks plus installer fixtures; build compiles host and SwiftUI with warnings as errors. No app launch or live route writes were performed.
- Injected Audio backend covers duplicate names/stable UIDs, independent routes, persisted ordered preferences/fallback, missing and returning USB/monitor devices, current-route preservation, manual/external override, input-only topology changes, Resume, connected Bluetooth protection, failed observation, ambiguous legacy names, and stop cleanup. Existing Bluetooth reconnect/protection/race checks pass through an injected routing callback.
- A read-only CoreAudio discovery executable found 11 devices with 11 unique UIDs; both current defaults resolved to discovered devices with the appropriate direction. Route writes are compiled, not hardware-validated. Physical headset reconnect, USB unplug, monitor wake, and actual microphone/output selection need manual acceptance. Device changes are detected by a two-second poll; transient disconnect/reconnect between polls is not observable. UIDs are shown to distinguish duplicate names.
- Automatic Audio behavior defaults off. The routing owner stays loaded for Bluetooth's existing post-connect behavior when only the Audio panel is disabled. Explicitly protected Bluetooth devices and an active Bluetooth output block automatic takeover; manual selection remains available. Third-party routing applications can still race an OS write.
- Independent adversarial review prompted explicit Bluetooth protection readiness (unknown, busy, failed, legacy-owned, or older-than-ten-second observations defer output routing), per-direction retry after failures/protection, and retained-owner re-enable reconciliation. Integration fixtures exercise the real BluetoothModule callback into injected Audio, startup deferral, legacy requests, and unload cancellation. Failed discovery/current-route reads reject callbacks; input write failures do not starve output.
- Follow-up review identified lost legacy post-connect requests after transient Audio failures. The owner now retains those requests for retry, validates Bluetooth policy/connection state before each write, and cancels on manual intent, policy changes, unavailable/ambiguous targets, or stop. Tests cover observation/write failure recovery and cancellation; turning automatic routing off retains manual overrides.
- Independent GPT-6.1 Sol review found two additional lifecycle boundaries: disabling the retained Audio owner reset overrides, and Bluetooth discovery could fail before forwarding post-connect intent. Disable/re-enable now preserves overrides (re-enable schedules rules without simulating topology change). Bluetooth retains successful connection addresses for protected post-connect discovery retry. Regression tests prove an eligible Bluetooth request cannot replace a retained manual route, and a discovery failure recovers without reconnecting while rechecking arriving headphones.
- Sol follow-up found an off/on-before-poll cancellation edge. Disabling Bluetooth routing/reconnection immediately clears pending intent, removing selected targets immediately drops their pending addresses, and canceled-cycle progress cannot recreate intent. Tests cover fast output-policy toggling after discovery failure and toggling during a blocked connection before connected progress is delivered.
- A further Sol follow-up found already-forwarded Audio intent could outlive policy disable if a fresh Bluetooth poll completed before Audio polled. Audio now captures the policy generation on receipt and verifies it before retry; policy/target changes, manual Bluetooth actions, observed disconnects, suspension, and stop invalidate generations. Regressions cover downstream off/on plus a fresh successful observation and target removal/reselection.
# Clipboard 5A / 5B

Acceptance: independent GPT-6.1 Sol adversarial review of `e283d5d..101c0e3` returned **CLEAN**, with no actionable warnings/blockers. Final `bash test.sh`: 256 isolated checks plus installer checks passed; native build/signature verification and `git diff --check` passed. Remaining manual acceptance limits are destination focus/shortcut behavior and live-app responsiveness near the archive size ceiling; no app was launched and no real clipboard/history was accessed.

Persistence switch correction: the native module publishes requested disk persistence while recovery is pending, with cleanup status shown separately, so an explicit switch Off still deletes the archive and saves Off after startup failure. Fake-backend/native-module regressions verify the displayed switch state and Off action. No real clipboard/history is touched.

Final lifecycle correction: quit preparation suspends Spaces reversibly instead of permanently unloading its observer/callback. A pending-termination guard prevents saved gesture activation during draining; canceled quit requests saved-state restoration under normal readiness/permission checks. The actual `applicationShouldTerminate` path is tested with an injected reply callback, fake in-flight gesture phases, fake clipboard, and failed late deletion, verifying observer/callback retention and restoration request without posting input or launching the app. Latest suite: 254 isolated checks plus installer checks passed.

Sol review follow-up: retention changes now use requested persistence even while startup recovery is pending, so the Stepper cannot accidentally take the destructive disable path. Quit quiesces recording/polling and rechecks disk cleanup in the final asynchronous completion before approving termination; canceled quit resumes polling but leaves recording paused. Injected native-module/host tests verify failed actual archive load, retention action during failed startup, late deletion failure during quit, and recovery before quit approval. Latest full suite: 250 isolated checks plus installer checks passed; `git diff --check` passed.

Follow-up review identified a startup-load/save failure path that could overwrite an unrecovered archive. Startup now stays pending, retries load/prune/save on idle polling, prevents recording before recovery, and recovers the existing archive before a subsequent Enable can save. Explicit Clear/disable can discard the archive. Fake-backend regressions cover failed startup → Enable while failing → recovered Enable, and idle startup recovery. Full suite after this fix: 243 isolated checks plus installer checks passed.

`bash test.sh` builds the native host/UI and exercises clipboard policy exclusively with an in-memory fake pasteboard, injected clock/source app, and a unique temporary archive. No real clipboard content is read, snapshotted, written, or logged by these tests. Coverage: paused startup/resume, duplicate and oversized text, marked/excluded/unknown-source content, racing reads, copy recapture prevention, 100-entry cap, memory-only disk absence, opt-in restart/expiry/pins, per-image and total image caps, disk deletion, exclusion purging, Clear, persistence disable, and module shutdown.

The archive embeds image bytes in one bounded JSON file, so deletion and expiry cannot orphan separate image files. PNG is the initial supported image representation. Polling samples every 500 ms; intermediate copies faster than the poll may be missed. Exclusions use the foreground app at sampling time because NSPasteboard does not reliably expose the originating application. Pins bypass age expiry but not hard count/byte caps.

Native panel/shortcut compile validation passed; interactive focus preservation, keyboard navigation, and shortcut conflict behavior still require a manual check. The app was not launched for this change and recording was not enabled against the user's clipboard.

Independent adversarial review of the initial clipboard commit identified archive encoding expansion, nontransactional persistence configuration, missing disk-failure retries, exclusion draft loss, and selection redirection. Regression checks now exercise an over-64-MiB valid archive across restart, injected enable/delete/Clear/expiry/exclusion failures with idle retry, draft preservation, stable UUID selection, and synthetic Return/keypad Enter/Escape events delivered directly to the table (never posted to the OS). The archive has a matching 96-MiB encoded read/write ceiling and rejects oversized files without deleting them. Pending writes/cleanup are visible; orderly module unload and quit wait for successful retry. Force quit/crash during an actual filesystem failure can still leave the last successfully written archive. Right-click an entry for Pin/Delete, or navigate from search with arrow keys and use the buttons. Full suite: 239 isolated checks plus installer checks passed.
# Mouse controls 4A/4B qualification gates

Read-only inspection on macOS **26.6.2 (25G83)**, 2026-10-14:

- `defaults read -g com.apple.mouse.scaling` and `com.apple.mouse.linear` both
  reported absent keys. Absence is not an explicit default and must be restored
  by deletion, not by writing a guessed value.
- The installed SDK exposes `IOHIDGet/SetMouseAcceleration` and
  `IOHIDGet/SetAccelerationWithKey` in `IOKit/hidsystem/IOHIDLib.h`, deprecated
  since 10.12. These declarations alone do not verify effective mouse-only
  tracking, independent acceleration control, persistence or reconnect behavior
  on Tahoe. No live writer is included until those properties are established.
- Public `CGEventTypes.h` provides continuous scrolling and phase metadata and
  process/user source fields, but no documented physical-device identifier for
  scroll events. A discrete event is not proof of a physical wheel mouse.
  Device enumeration or timestamp matching does not establish event attribution.
  All production scroll events therefore pass through; no tap is installed.

The Mouse panel is integrated into module settings and the host lifecycle. It
shows disabled controls with scope and reasons. The injected pointer transaction
captures original absent/value states before writes; repeated changes retain the
first baseline; partial failures roll back; failed rollback or journal deletion
retains recovery. Startup/disable/quit attempt restoration and report failure.
The production backend deliberately refuses all writes, including recovery from
an unrecognized backend. No current production operation creates a journal.

Policy tests use only fake backends and temporary files. Wheel policy transforms
only an explicitly verified wheel source, and passes unknown/trackpad, momentum,
gesture, horizontal/diagonal and modifier-assisted samples through unchanged.
That policy seam is not a device classifier or an installed interceptor.

**Remaining qualification:** physical mouse alongside trackpad, pointer speed and
acceleration independence, absent-key restoration effectiveness, mouse reconnect,
crash recovery with real settings, real wheel attribution, natural-trackpad
direction, momentum, horizontal/modifier scrolling and event-count preservation.
No actual pointer settings were changed, no synthetic input was posted, and no
user app was launched/relaunched or quit for this increment. The existing suite
launches disposable watchdog fixtures. `bash test.sh` passed: **230 isolated
checks** (31 new Mouse assertions) and **7 installer scenarios**; the signed app
build compiles the host UI. 4A and 4B remain incomplete.
