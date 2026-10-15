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
checks, and runs installer tests. Latest run: **3,720 isolated checks passed**, all
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
- One-window reuse, preserved drafts, simultaneous Settings/popup use, and native
  clipboard panel nonactivation under actual app activation/deactivation.
- Permission request/deny/regrant flows under the installed app's real TCC identity.
- Hardware checks for display confirmation/recovery, Bluetooth, audio routing,
  pointer tuning, real window restoration, and power assertions.
- Live asynchronous quit veto/cancellation with the replacement UI open.

These checks must be deliberate and coordinated with the user; do not infer success
from isolated test counts. Parent-session independent review and safe relaunch are
still pending.
