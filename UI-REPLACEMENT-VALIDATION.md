# UI replacement validation

## Production scope

Implemented B–D from [UI-UX-PLAN.md](UI-UX-PLAN.md). The user waived the preview
approval gate. Independent review is still required; this record is not acceptance.

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
checks, and runs installer tests. Latest run: **3,765 isolated checks passed**, all
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
from isolated test counts. Parent-session independent review and safe relaunch are
still pending.
