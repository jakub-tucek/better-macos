# Validation and release acceptance

## Evidence index

Commands and source paths in code spans refer to the repository root. Historical
records retain paths and status from their named revisions; relocated links point
to the current documentation. Native/hardware acceptance remains open.

- [CLT/Xcode compatibility and combined SwiftPM integration](clt-compatibility.md)
- [Built-in registration integration and limits](../architecture/builtin-registration.md#main-integration--2026-10-15)
- [Keep awake owned-feature integration and limits](../architecture/keep-awake-feature.md#main-integration--2026-10-15)
- [Mechanical source organization and byte-preservation checks](source-organization.md)
- [Core recovery regressions](release-core.md) · [Host transactions](host-transactions.md)
- [Bluetooth stale-banner recovery; power-on cause remains unknown](bluetooth-error-recovery.md#main-integration--2026-10-15)
- [Login registration-intent UI; real autostart unverified](login-diagnosis.md#main-integration--2026-10-15)
- [Keep awake](awake.md) · [Window positions](window-positions.md)
- [Clipboard UI](clipboard-ui.md) · [Compact UI](compact-ui.md)
- [UI replacement](ui-replacement.md) · [Release UI polish](release-ui.md)
- [Historical UI consolidation and storage-intent cases](ui-consolidation.md)
- [Packaging](packaging.md) · [Release checklist](../releases/checklist.md)

## Acceptance matrix and baseline · 2026-10-15

The baseline report at `f359f42` records **3,997 isolated checks and seven installer
checks**, including native compilation/signature checks. See the
[countdown integration record](awake.md#shared-readable-countdown-2026-10-15).
This docs-only audit did not rerun the suite or launch the app. The documented
environment includes Apple Silicon/macOS **26.6.2 (25G83)**; macOS 15 is the deployment
target, not evidence of a full supported-OS acceptance sweep.

| Capability | Implementation / isolated evidence | Native evidence recorded | Live acceptance gap | Evidence |
| --- | --- | --- | --- | --- |
| Monitor switching, arrangement, recovery | Implemented; identity/last-display safeguards, helper/watchdog and lifecycle tests | Disposable helper/watchdog processes | Physical disable/restore, crash recovery, wake/reconnect; cannot guarantee WindowServer/driver recovery | [Monitor management](#monitor-management) |
| Desktop switching / matched edges | Implemented; vendored engine checks, injected phases and geometry | Compilation and source/API inspection | Physical gestures/crossings, latency, permission transitions | [Space engine](#space-animation--strafe), [edges](#matched-screen-edges) |
| Named window layouts and automation | Implemented; matching, bounds, settling, exclusions | Native AX boundary compiles | Multi-app restore, reconnect/wake cycles, unsupported windows; current desktop only | [Window validation](window-positions.md) |
| Audio / Bluetooth | Implemented; injected discovery, routing/protection/retry and shutdown tests | Read-only CoreAudio discovery | Actual input/output writes, headset/USB/monitor cycles, Bluetooth authorization | [Audio](#audio-2a--2b) |
| Keep awake | Timed and app reasons implemented; injected power/lifecycle tests | Mounted native duration/focus/action harness | Real assertions, physical sleep/lid-close, live interactions | [Awake validation](awake.md) |
| Clipboard capture / retention | Implemented; fake pasteboard, temporary archive and failure/retry tests | Native panel compilation and injected presentation tests | Live global shortcut, destination focus, VoiceOver, large-history responsiveness | [Storage evidence](#clipboard-5a--5b), [panel evidence](clipboard-ui.md) |
| Mouse 4A | Implemented; mouse-class runtime backend and injected rollback tests | Read-only IOKit capability reads | Physical effectiveness, trackpad invariance, reconnect/restoration | [4A evidence](#real-4a-backend-follow-up) |
| Mouse 4B | Unsupported; no production wheel tap | No qualified attribution backend | Reliable wheel/trackpad source attribution before implementation | [Qualification gates](#mouse-controls-4a4b-qualification-gates) |
| Hold to quit | Implemented; countdown/input state-machine tests | Native HUD compiles | Layouts, secure input, full-screen placement, app save prompts | [Hold to quit](#hold-to-quit) |
| Animation / menu-bar controls | Implemented; preference restoration/recovery tests | Isolated live AppKit divider probe | App-specific motion, spacing effect, user icon arrangements/notch limits | [Lifecycle](#lifecycle-regression-coverage), [menu bar](#menu-bar-controls) |
| Widgets, Settings, guided setup | B–D implemented; injected production action/transaction tests | Fixtures, native owned-window/focus harnesses; signed rebuild/relaunch and Settings metadata recorded | E partial: live keyboard/VoiceOver, focus, long labels, appearance and hardware actions | [Replacement](ui-replacement.md), [compact popup](compact-ui.md) |
| Quit coordination | Implemented; admission/drain/cancel/approval regressions | Injected host/native termination seams | Live recovery/quit with active hardware operations | [Host validation](host-transactions.md), [terminology](../glossary.md) |
| Source install / updates | Implemented; thirteen mocked installer scenarios and four fresh-bundle fixture groups at `95e6433` | Apple Development build, strict signature and complete bundled notices verified | Final release revision/artifact verification; source install follows latest main, not an exact offered SHA | [Packaging](packaging.md), [installer](../../install.sh), [updater](../../Sources/App/SourceUpdates.swift) |

### Reviewed core integration · `dc96e9c` · 2026-10-15

Display-recovery ownership, setup display-awake assertion removal, watchdog
admission/executor authorization and unreadable-journal initialization/reload/save
preservation fixes are independently reviewed CLEAN and integrated. The supplied
final review reports **297 targeted checks** at source `ea47e60`; its implementer
record reports **4,201 isolated checks** before integration with the reviewed UI.
These are separate revision-bound results, not the combined-main count.

Combined main at `dc96e9c46e813d1608d3879f68f49fdfc3239a7a` passed
`bash test.sh`: **4,220 isolated checks**, thirteen mocked installer scenarios,
four fresh-bundle fixture groups and exact real signed-bundle notice comparisons.
Log: `build/release-core-integration.log`. Script syntax, source/built plist lint,
strict Apple Development signature, arm64/macOS 15+ metadata, version `0.4`/build `4`
and `git diff --check` passed. No live app/device acceptance or permission mutation
was performed; default fixtures remain isolated. The evidence-only commit does not
claim a final release artifact; rebuild the chosen final revision before distribution.

The prior UI/packaging integration at `95e6433` passed **4,016 isolated checks**,
thirteen mocked installer scenarios and four build fixture groups, including
complete bundled notices and strict Apple Development signature verification.
Signing-identity changes automatically rebuild. See [core regression evidence](release-core.md),
[exact integrated revisions and checks](../releases/checklist.md#current-evidence) and
[unreleased notes](../releases/1.0-notes-draft.md). Native/hardware acceptance, final
documentation/versioning and publication remain open; historical counts below are unchanged.

### Combined SwiftPM and CLT compatibility · `dff0491` · 2026-10-15

Clean sequential standalone CLT 27 and Xcode 27 runs at
`dff0491fa1ad3ce32a37f6009c75ce882ccefeae` each passed **4,226 legacy checks**,
**10 Swift Testing tests in three suites**, **13 mocked installer scenarios**,
compiler/build fixtures and real/relocated-bundle checks. Strict ad-hoc signatures,
notices, arm64/macOS 15+/SDK 27 metadata and embedded revision matched. Lint/format
across 42 files and offline tooling fixtures passed under both toolchains.
The earlier standalone-CLT `StateMacro` build gap is resolved for these tested tools,
not every declared minimum Swift version. See [combined compatibility evidence](clt-compatibility.md#combined-main-integration)
for exact toolchain/log paths, preserved failures and deferred installer preflight.
Native/hardware acceptance and final release/publication gates remain open.

### Built-in registration integration · `66056f0` · 2026-10-15

The independently reviewed CLEAN catalog/typed-choice preparation series is integrated
at `66056f0486e6ad84cdf81e75568cd3ed84945a99`. The single combined full run passed
**4,335 legacy checks**, **10 Swift Testing tests in three suites**, **13 mocked
installer scenarios**, compiler/build fixtures and real/relocated-bundle checks.
Lint/format passed across 44 files; tooling fixtures, strict signature, notices,
plist/revision and arm64/macOS 15+/SDK 27 metadata passed. The CLT state compiler
fixture also passed; this run does not add another full CLT or minimum-toolchain claim.
See [revision/log details and remaining scope](../architecture/builtin-registration.md#main-integration--2026-10-15).
Host composition/quit authority, native/hardware acceptance and publication gates remain unchanged.

### Source organization integration · `480e957` · 2026-10-15

The independently reviewed CLEAN source-organization series is integrated at
`480e957b66df14f870ce43a96fde1a0ba78ec9ba`. All **31 moved app Swift files are
byte-identical** to prior main; build/test input order, flags, package ownership and
four lint exceptions are unchanged except paths. One combined full run passed
**4,335 legacy checks**, **10 policy tests in three suites**, **13 mocked installer
scenarios**, compiler/build fixtures and real/relocated packaging checks. Lint/format
across 44 files, expanded tooling fixtures and offline CI whitespace fixtures passed.
See [revision/log details](source-organization.md#main-integration--2026-10-15).
CI remains configured but hosted execution unverified; folders do not create new
packages or a complete lifecycle framework. Native/hardware gates remain open.

## How to read the historical records

The sections below retain evidence from earlier increments. Counts, “latest/final”
labels, review status, and statements about then-current UI/backend behavior belong
to those revisions, not the current tree. Do not replace historical counts with the
baseline count above. The initial Mouse foundation predates the implemented 4A backend.

The old card/navbar/panel descriptions in
[UI consolidation](ui-consolidation.md) predate the widget popup and full
Settings replacement. Use [replacement validation](ui-replacement.md),
[compact UI validation](compact-ui.md), and
[clipboard UI validation](clipboard-ui.md) for later UI evidence. Those
records also retain revision-bound results; a CLEAN code review does not close live
acceptance. Existing storage-intent cases and [glossary](../glossary.md) remain relevant.

## Historical upstream validation · 2026-10-14

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

## Real 4A backend follow-up

The initial disabled-controls foundation described below has been superseded for
4A: a real opt-in IOKit backend now reads/writes `HIDMouseAcceleration` and
`HIDUseLinearScalingMouseAcceleration`. The installed SDK's
`IOHIDEventServiceKeys.h` says linear scaling only affects devices using
HIDMouseAcceleration; trackpad-specific and generic pointer keys are never written.
The backend uses IOHIDGet/SetAccelerationWithKey with the mouse key and
IOHIDCopy/SetCFTypeParameter for the linear flag. Deprecated acceleration functions
are isolated in a small C compatibility boundary, not guessed private symbols.

Primary sources:
- [Apple IOHID event-service keys](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOKit/hid/IOHIDEventServiceKeys.h)
- [Apple IOEventStatusAPI implementation](https://github.com/apple-oss-distributions/IOKitUser/blob/main/hidsystem.subproj/IOEventStatusAPI.c)

Real read-only API inspection on this Mac succeeded: linear mode **0**, mouse
tracking **0.6875**. The API can obtain values from the event system even when
IOHIDSystem registry entries omit the mouse-specific key. Acceleration uses 16.16
fixed-point values. Capture stores effective explicit runtime values, not guessed
defaults. User preference keys remain untouched, including their original absence.
Absent/malformed runtime snapshots are rejected because this API does not provide
a qualified deletion operation. A missing linear flag or failed connection/read
disables Apply and reports the exact operation/IOKit result. Successful reads do
not guarantee write permission or hardware effects; Apply verifies readback and
rolls back on failure. No writer is invoked until the user clicks Apply.

All mice using that acceleration class are affected; third-party drivers may
ignore it. Tracking is the OS curve index, not a physical DPI or constant speed
multiplier. Turning acceleration off selects linear mouse scaling. Runtime
settings are restored on disable/quit and after interrupted sessions; no saved
override is automatically applied on startup. Reconnect or WindowServer changes
may reset runtime values; automatic reapplication is intentionally not implemented.
Physical effectiveness, trackpad invariance and reconnect remain unverified.
4B still installs no tap because reliable physical-device attribution was not
established. All wheel/trackpad events pass through unchanged.

Injected HID-boundary tests cover exact mouse-only operations, fixed-point
readback tolerance, explicit original restoration, invalid/absent rejection,
ignored writes, capability failure and transaction rollback. Development performs
only real capability reads, never real pointer writes or synthetic input.
`bash test.sh` passed **265 isolated checks** and **7 installer scenarios**, including
the signed app/UI build. Real write behavior was deliberately not exercised.

The independent GPT-6.1 Sol review of the real-backend increment identified one
warning: failed Apply rollback did not publish recovery state to the host UI.
The fix exposes that state through the actual lifecycle Apply entry point; tests
verify global Restore eligibility, retained ownership/journal and successful
rollback remaining idle. Review notes also prompted injected-owner capability
reads, an explicit read/refresh button, actual-current draft initialization while
preserving unsaved edits, source-contract checks for mouse keys, setter failures
and malformed read tests. Fixed-point tolerance/range validators are shared.
Independent GPT-6.1 Sol follow-up review of `f46e1dc..dce9695` returned **CLEAN**,
with no actionable blockers or warnings. Two minor notes (historical comments
and a repeated range literal) were aligned with the live opt-in implementation.

## Initial foundation validation (historical)

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
The host's injected lifecycle coordinator is tested with isolated preferences:
disabled startup recovery, failed disable retaining the enabled choice and owner,
retry state publication, and quit after success/failure. Unrestorable historical
or corrupt journals stay visible and retained but do not block normal quit or
module disable. This session's unresolved writes remain owned until recovery.
Failed cleanup enters recovery-only state and blocks subsequent writes, including
same-instance updates. Missing active journals cannot become a new baseline.
The production backend deliberately refuses all writes, including recovery from
an unrecognized backend. No current production operation creates a journal.
File persistence currently covers process-crash recovery, not a verified
power-loss durability guarantee; qualification of a live writer must address that.

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
launches disposable watchdog fixtures. `bash test.sh` passed: **249 isolated
checks** (50 new Mouse assertions) and **7 installer scenarios**; the signed app
build compiles the host UI. 4A and 4B remain incomplete.

Independent read-only adversarial reviews (Codex and OpenCode) of the feature
commit found three warnings: recovery-state reuse after failed cleanup, impossible
historical recovery blocking quit, and missing host lifecycle coverage. The
follow-up fix addresses all three with the regression scenarios above. DRY review
found no existing generic transaction helper to reuse; hardware/source attribution
and power-loss durability remain explicit qualification limitations.

Independent read-only follow-up review of `e283d5d..01ecc0e` returned **CLEAN**:
all three warnings were confirmed fixed, with no remaining actionable blockers or
warnings. The reviewer did not rerun tests. Remaining assumptions are serialized
single-owner access and retaining the explicit backend capability boundary.
The final explicit GPT-6.1 Sol review also returned CLEAN, with one minor note:
successful retry left a stale error banner. A presentation fix clears only the
mouse-owned error while retaining unrelated errors, with regression coverage.
