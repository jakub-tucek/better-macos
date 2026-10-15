# UI replacement validation

## Production scope

Implemented B–D from [UI-UX-PLAN.md](UI-UX-PLAN.md). The user waived the preview
approval gate. Parent-session independent review reports **CLEAN** at `7e3974cd`;
native acceptance remains partial. This record is not full acceptance.

- Direct, screen-bounded widget popup; separate reusable/resizable Settings window.
- Six typed widgets with compact/expanded treatments, editor drafts, gallery,
  drag and accessible button ordering, removal, suggestions, and persistent targets.
- Nonremovable safety/recovery controls and Stop for hidden active awake sessions.
- Seven Settings groups with independent feature switches and all prior controls.
- First-run Skip and repeat setup; selected-only shared configuration; contextual
  access guidance; widget draft; review, confirmation, sequential Finish and results.
- Auto-checkpointed configuration drafts after setup starts; explicit Resume only.
  Cancel and the native close button discard drafts; Save draft & close retains one.
  The close button cannot dismiss an applying Finish transaction.
- Selecting Clipboard never starts recording or disk storage. Disk history has a
  separate explicit configuration choice. Mouse proposals require later Apply.
- Window naming/capture remains in Displays; setup only drafts restoration policy.
  No capture is required to enable the feature or add its widget.

## Automated evidence

Run from the main checkout:

```sh
bash test.sh
build/isolated-tests --preview build/ui-fixtures
git diff --check
```

`test.sh` builds native SwiftUI/AppKit code with warnings as errors, runs isolated
checks, and runs installer tests. Latest run: **3,780 isolated checks passed**, all
seven installer checks passed, and `git diff --check` was clean. The fixture render
command also passed; popup light/dark, grouped Displays, wizard selection, and empty
recovery fixtures were inspected. New coverage includes:

- Widget migration, single instances, draft cancellation, order/presentation,
  unknown kinds, missing targets, and preservation across relaunch.
- Settings destinations for every feature and legacy launch-flag routing.
- Selected-only wizard steps, Back, empty widget choices, repeat setup, checkpoint
  resume/cancel, validation, and unresolved contextual access.
- Shared draft controls do not invoke live feature operations.
- Actual host Finish with fake clipboard/archive: Clipboard selection alone cannot
  capture or persist; storage failure is reported separately from layout success.
- Actual host widget Done and setup Finish callbacks during an asynchronous quit;
  widget persistence works again after the quit is canceled, without ending capture.
- Window configuration, permission, capture, and restore admission, including queued
  restore steps; existing host/clipboard/display/Mouse regression coverage remains.

## Independent review fixes

The first independent review blocked the replacement. These fixes await follow-up
review; neither implementation checkboxes nor test counts imply native acceptance.

1. **Activation ordering:** actual host Finish uses fake Audio, awake, and menu-spacing
   backends with obsolete saved policies. Tests assert zero intermediate route writes,
   assertion acquisitions, and spacing writes when the reviewed draft disables them.
   All newly enabled owners receive reviewed preferences before any activation can
   start a shared consumer. Refused activation restores only unactivated preferences;
   tests verify existing recovery journals and unselected settings are untouched.
2. **Authoritative outcomes:** Audio and awake expose feature-owned failure state;
   Bluetooth reports its actual authorization, backend, radio, discovery and connection
   state. Host operations retain typed activation failures. Tests exercise actual
   Finish with routing/assertion/spacing failures, repeated identical error text,
   denied Bluetooth access, radio off, and Bluetooth backend failure. A global error
   banner is not used to infer success. Unfinished hardware work is explicitly pending.
3. **Interaction seams:** the production Edit/Done/Cancel buttons use shared editor
   sessions. Tests invoke those same actions through the actual host persistence
   callback, including rejection during quit and successful retry after cancellation.
   Actual offscreen native Settings windows/hosting controllers are reused across host
   links while preserving the Settings editor draft. An asynchronous Finish uses fake
   animation writes and a fake client-restart callback; native `performClose`, Cancel,
   duplicate Finish, and a retained Skip cannot dismiss or repeat it. Completion shows
   results, native close becomes available, and repeat setup starts a current draft.

The window harness injects a presenter that never orders windows front or activates
the app. It exercises native window/delegate behavior and production action seams,
not coordinate clicks or VoiceOver traversal of SwiftUI buttons. No TCC grant is
needed for this harness; live accessibility/button traversal remains a manual gap.

### Follow-up: saved desktop intent versus runtime interception

Follow-up review identified a separate setup ordering bug for an already enabled
Animations module. Runtime interception being Off did not imply that saved desktop
intent was Off, and animation completion could restore an obsolete saved On choice.
The readiness guard also returned Pending before persisting a reviewed On choice.

Regression tests were added before the fix, using the actual host Finish callback,
isolated preferences, fake animation writes/restarts, a fake gesture engine, and a
fake interceptor. All three cases failed before the fix:

```sh
bash test.sh
build/isolated-tests --setup-space-case animation-on-desktop-off
build/isolated-tests --setup-space-case pending-on
```

The first command failed the saved-On/runtime-Off → reviewed-Off case. The next
two independently failed zero-intermediate-activation and retained-pending-intent
assertions. Failure logs are under ignored `build/ui-desktop-*-red.log`.

Setup now installs the reviewed desktop intent through `SpacesModule` before any
animation application or restoration. Off always persists and suspends, even if
runtime interception was already inactive. On is saved without requesting access
or starting interception. Host automatic restoration waits until setup has handled
the reviewed animation policy; runtime reconciliation then requires permission,
readiness, availability, and a completed gesture drain. Pending On remains saved
and can activate only when those prerequisites later hold.

The full suite now passes all three regressions, including a later ready refresh
which cannot resurrect reviewed Off and does restore reviewed pending On once.
A separate ordinary-toggle test confirms that animation Off still suspends runtime
interception while preserving saved desktop On, and ordinary animation On restores
that saved choice. No live input tap, swipe, system animation write, app restart,
clipboard access, or app launch/quit is used by these regression fixtures.

The test-only dependency seams inject host readiness and the interceptor factory;
production defaults still use the existing watchdog state and `SwipeInterceptor`.
Follow-up independent review and live native acceptance remain pending.

### Follow-up: permission-passive automatic desktop restoration

Review found that a ready refresh after denied-access setup could call the explicit
permission-requesting enable path and consume the pending restore ticket. An actual
host regression with fake permission checking/requesting failed before the fix:
`build/ui-desktop-permission-red.log` records the ready-refresh failure. A second
regression exposed that ordinary Animation On did not re-arm an existing saved
desktop choice after permission revocation (`ui-desktop-permission-animation-red.log`).
Both logs are in ignored `build/`; no real access request was made.

`SpacesModule.restoreSavedState()` now checks permission before attempting On and
consumes the ticket only after successful restoration. Its activation helper cannot
request access on the automatic path, including if permission changes between checks.
The explicit user toggle still uses the permission-requesting path. Ordinary
Animation On re-arms an existing choice even when access is missing, while preserving
the legacy unset-choice behavior. No preference is silently opted into On by this fix.

The passing real-host fixture verifies denied setup → repeated ready refreshes →
permission granted: zero implicit access requests, a retained ticket while denied,
exactly one eventual fake activation, and no extra activation on repeated refresh.
Additional checks cover direct automatic callers, revocation between permission
checks, failed-start retry, explicit-toggle request semantics, ordinary animation
Off/On after revocation, canceled-quit-style restore requests, and the unset default.

Automatic caller audit: setup continuation and ordinary host refresh share this
central passive restore method. Animation completion and canceled quit only schedule
restore intent. Screen-edge and Hold-to-quit startup use read-only trust checks;
window Accessibility requests remain on their explicit button, and Bluetooth access
requests remain on explicit controls/launch flags. No other automatic prompt path
was found in these call sites. This inspection and fixture coverage do not replace
installed-app TCC or live input acceptance; independent review remains pending.

The new tests use fake clipboard, archive, and window backends and isolated preference
suites. No real clipboard/history was read, no live audio route/pointer/display/window
changes were requested, and the running app was not relaunched or quit. The existing
suite uses disposable watchdog children and installer fakes, plus read-only runtime
capability checks; these are not live feature acceptance.

## Fixture rendering and E gaps

The preview command renders offscreen native fixture windows (no activation or live
actions), including light/dark popup, all Settings groups, wizard selection/config/
permissions/widgets/review, long display labels, empty home, and recovery with no
widgets. Output is under ignored `build/ui-fixtures/`.

Static fixtures are useful evidence of layout/rendering, not evidence that controls
were clicked or that VoiceOver/keyboard traversal works. E remains **open**:

- Live keyboard and VoiceOver traversal, drag/drop, focus transfer, native resizing,
  large text, light/dark appearance, long device names, and short-screen scrolling.
- Live focus/activation, simultaneous Settings/popup use, and clipboard panel
  nonactivation under actual app activation/deactivation. One-window identity,
  hosting-controller reuse, editor preservation across Settings links, and Finish
  close blocking are now covered by the offscreen native host harness above.
- Permission request/deny/regrant flows under the installed app's real TCC identity.
- Hardware checks for display confirmation/recovery, Bluetooth, audio routing,
  pointer tuning, real window restoration, and power assertions.
- Live asynchronous quit veto/cancellation with the replacement UI open.

These checks must be deliberate and coordinated with the user; do not infer success
from isolated test counts. See the subsequent review and release evidence below.

## CLEAN review and safe native release pass — 2026-10-15

The parent session supplied a CLEAN production UI review at
`7e3974cd51e156c000101346f3068a44b868e800`, with prior findings resolved.
The 3,780 isolated / seven installer checks above are the existing evidence, not
a new run in this pass. No production code changed and the full suite was not repeated.

### Completed

- Sent normal AppleScript Quit to bundle ID `io.github.jakub-tucek.mac-utils`.
  It returned successfully; `pgrep -fl 'fix-mac-os|Fix macOS'` then found neither
  the GUI nor watchdog process. No kill, forced quit, or veto bypass was used.
- Ran `bash build.sh` from the main checkout at the reviewed revision. Compilation
  with warnings as errors, signing, and strict signature verification succeeded.
- Relaunched `build/Fix macOS.app --show-dashboard`. Read-only
  `NSRunningApplication`/bundle inspection confirmed the checkout's app and embedded
  revision `7e3974cd51e156c000101346f3068a44b868e800`.
- After a second successful normal quit and process-exit verification, launched with
  `--show-modules` (the existing General Settings route). CG window metadata showed
  one on-screen app-owned window, ID 9629, 680 × 480 at global top-left (3519, 30).
  Its bounds fit the right-hand 1920 × 1200 display. No window was resized or moved.
- Reopening that same running app retained PID 81892 and window ID 9629 with the
  same bounds. This verifies retention across app reopen, **not** repeated gear-click
  Settings reuse, sidebar traversal, or preservation of a live editor draft.
- Normally quit again, verified both processes gone, and relaunched with
  `--show-dashboard` as the final requested route, rather than leaving Settings open.
  Final process check found GUI PID 85539 and watchdog PID 85545; bundle inspection
  again confirmed the reviewed embedded revision. The final documentation-only
  commit does not change that running executable revision.
- `git diff --check` passed. Existing preferences were not intentionally edited;
  no feature controls, setup Finish, permission controls, or hardware actions were
  invoked. No clipboard contents/history were read or written by this acceptance
  pass, and no screenshot of any app or desktop was captured. Normal app lifecycle
  and enabled background modules were not suppressed or reconfigured.

### Blocked / not accepted

The native helper's `AXIsProcessTrusted()` was false. Read-only AX window inspection
returned `-25211` (`AXError.apiDisabled`). `CGPreflightScreenCaptureAccess()` was
also false, so no capture was attempted and no permission request was made. No
System Events automation, synthetic clicks, permission escalation, or external
application inspection was used.

The popup was requested at launch/reopen, but there was no app-owned on-screen popup
in the subsequent CG metadata sample; the app reported inactive. This does **not**
establish whether the transient popup appeared then dismissed, or establish popup
geometry, focus transfer, clipping, or rendering correctness. Final launch route is
popup; persistent visible popup state cannot be confirmed from this environment.

Live Settings content/gear reuse, popup/widget interactions, wizard traversal,
keyboard/VoiceOver, focus, resizing, drag/drop, short-screen scrolling and visual
appearance remain unverified. Wizard Finish, real permission flows, feature actions,
quit veto/cancellation and hardware recovery were deliberately not exercised.
No release-critical rendering defect could be confirmed with these restricted
observations; that is not a clean visual inspection. E remains **partial/open**.
