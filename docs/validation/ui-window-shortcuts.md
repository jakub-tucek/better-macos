# UI polish and window shortcuts

## UI source audit

Reviewed the Settings shell, quick-action popup/editor, shared feature controls,
guided setup, and window-layout view against the existing host-owned action paths.

- Settings now places each feature's enable switch directly above its controls.
  Displays and arrangement retain their shared configuration and recovery surface.
- Sidebar symbols and section headings improve scanning. Content width is bounded
  on large windows; narrow windows retain scrolling and multiline descriptions.
- Shared switches use native SwiftUI controls for keyboard, accessibility,
  appearance and system motion behavior. Cards use a subtle adaptive border.
- Widget editing has a clear primary Done action; empty layouts explain the next
  step. Cancel still discards the draft, and removing a widget does not disable it.
- Setup continues to stage choices until Finish. Permission grants, recovery
  controls, explicit Mouse Apply and Clipboard retention remain separate actions.

The signed app build, pinned lint and format checks passed for the initial UI
changes. The first full-suite attempt timed out in the standalone diagnostics
runner after 600 seconds; an isolated rerun passed all 160 checks. No production
diagnostics change was made. Full integrated results are recorded below when run.

Native appearance, VoiceOver and physical-device acceptance require live checks;
compilation and injected tests do not establish them.

The `b5ecb25` isolated UI runner also passed the four light/dark native Settings
and setup scroll-reset checks (`--release-ui-fixtures build`). Rendered audio and
Clipboard fixtures were inspected in light/dark appearance. These hidden-window
fixtures use fake data, without launching the app or touching user devices.

Intermediate integrated runs caught two UI fixture failures: the new empty state
was taller than one compact widget (fixed by putting its actions on one row), and
the first-click fixture expected an outer event monitor to observe mouse-up while
native switch tracking consumed it. The latter still dispatched the intended
injected display action exactly once. These failed runs are not full-suite passes.

## Rectangle-style keyboard controls

Reference: [Rectangle](https://github.com/rxhanson/Rectangle), including its documented
actions and standard Control–Option shortcut preset (reviewed 2026-10-21).
This is first-party native implementation, with no copied window engine, new vendor,
package dependency, external app requirement or Rectangle configuration import.

Enable **Displays → Window positions → Window keyboard shortcuts**. Accessibility
and the existing host/display readiness checks must pass. Defaults remain off.

| Keys | Action |
| --- | --- |
| ⌃⌥ ← / → / ↑ / ↓ | Left / right / top / bottom half |
| ⌃⌥ U / I / J / K | Top left / top right / bottom left / bottom right |
| ⌃⌥ Return | Maximize within the usable display area |
| ⌃⌥ C | Center |
| ⌃⌥ Delete | Restore original session frame |
| ⌃⌥⌘ ← / → | Previous / next display in spatial order |

Letter shortcuts use US physical key positions. Display movement preserves size
when it fits, maps position proportionally, and clamps to the destination's usable
area. Dock/menu-bar insets come from the existing display backend. Restore retains
up to 64 original frames while this feature owner remains loaded, and clamps after
display removal. It is available after failed/partial moves too.

Registration is all-or-nothing. A conflict releases the entire preset and offers
Retry; quit Rectangle or another conflicting window manager before retrying.
Readiness loss and stop unregister shortcuts; callbacks also check registration
generation, host admission, permission, exclusions and focused-window eligibility.
A manual shortcut cancels queued layout restoration. The AX writer verifies focus
again immediately before writing and reports failure if the app refuses the exact
requested frame. Existing conservative snapshot/identity safeguards still apply.

Scope: ordinary windows on the current Space. No drag snapping, custom bindings,
Space transfers or full-screen control. App minimum sizes and incomplete AX
metadata may prevent a move. Excluded apps are not moved; their shortcuts are
still reserved while the preset is active.

Injected tests cover geometry, odd-sized splits, negative-origin displays, display
ordering/removal, invalid geometry, opt-in, host closure, exclusion, unsupported
windows, permission loss, stale callbacks, conflict/retry, failed movement,
restore, disable and stop. Native Carbon delivery and real multi-app AX behavior
remain live acceptance gaps.

## Completed checks · 2026-10-21

After the popup and native event-fixture fixes:

- `bash test.sh`: **4,841 isolated checks** (including 36 new window-shortcut
  checks), **10 policy tests in three suites**, **160 diagnostics**, **31 reader**,
  **39 Bluetooth permission**, **190 Bluetooth observation**, C gesture checks,
  packaging/build fixtures and **13 installer scenarios** passed.
- `build/isolated-tests --render-ui`: **4,842 checks** passed, including distinct
  native switch on/off rendering without forcing a particular accent color.
- Final `--release-ui-fixtures build`: four native scroll-reset checks passed;
  audio, Clipboard and new Windows settings inspected in light/dark appearance.
  Compact empty, active and editing popup fixtures were also inspected.
- Pinned lint/format checks across **73 Swift files**, and `git diff --check`, passed.

Logs and rendered fixtures reuse `build/`: `ui-window-final.log`,
`native-render-check.log`, `final-ui-fixtures.log`, `ui-window-lint.log`,
`ui-window-format.log`. No branch, worktree, vendor or alternative build root was
created. App build/signing ran through the existing staged replacement path.
No installed-app launch, live global shortcut registration, window movement,
permission change or hardware action was performed. These checks do not close
the project's existing hardware/VoiceOver acceptance gaps.

## Settings refresh · 2026-10-22

Category headers now stay visible while settings scroll. General uses compact
setup/activity rows and a native login switch; Quick actions shows saved widget
presentation and links disabled features to Settings. Windows adds informational
shortcut diagrams, consolidates capture and saved layouts, and names its automatic
restore/exclusions disclosure. Shortcut diagrams do not dispatch window actions.

The initial header container caused native sidebar selection to be absent on first
open. The existing first-key navigation test caught this; using a scroll-view top
inset preserves selection. The native scroll-reset fixture now measures document
top relative to the actual inset (observed offset -87 with inset 87), rather than
assuming top is always zero. The original proven nonzero pre-navigation offset
and first-click/first-key assertions remain. Failed attempts remain in
`build/ui-refresh-test.log` and `build/ui-refresh-final-test.log`.

Final `bash test.sh` passed **5,076 isolated checks**, named regression/policy suites,
packaging/build checks and **13 installer scenarios**. Lint/format and whitespace
checks passed. `--release-ui-fixtures build` passed all four light/dark navigation
checks; General, Quick actions and Windows snapshots were inspected, including
the 680 × 480 Windows fixture. Logs: `build/ui-refresh-verified.log`,
`build/ui-refresh-fixtures.log`, `build/ui-refresh-{lint,format}.log`.
Hidden fixtures use injected state; no installed-app launch or live device actions.

## Open design · 2026-10-22

Implements the selected Open direction from prototype `3586808`: horizontal native
category tabs, wider content, restrained headings and divider-based Settings
sections. The Settings-only environment style also flattens nested feature cards;
popup and setup retain their existing card presentation. Shortcut reference tiles
use quiet outlines in Settings.

The native handoff fixture now exercises segmented-control keyboard behavior:
Right Arrow focuses the next segment, Space selects it. It also checks the initial
Displays selection. The first attempt assumed arrows selected immediately and
failed (`build/open-design-test.log`). Minimum-width snapshots revealed intrinsic
control sizing clipped the navigation; explicit proposed-width sizing fixed it.
Light/dark fixtures now assert all seven tabs fit within the minimum-width window.

Final `bash test.sh`: **5,079 isolated checks**, supporting named suites,
packaging/build fixtures and **13 installer scenarios** passed. Pinned lint,
format and `git diff --check` passed. Native release UI fixtures passed; inspected
General dark, Windows light and minimum-width Windows light snapshots. Logs:
`build/open-design-verified.log`, `build/open-design-fixtures.log`,
`build/open-design-{lint,format}.log`. Live app and VoiceOver acceptance remain open.

## Open layout correction · 2026-10-22

After user feedback that the first native version did not resemble the prototype,
replaced the segmented bar with underlined native button tabs and implemented the
workspace structure. At widths of 800 points and above, display controls and saved
layouts occupy the left column; window shortcuts and automation occupy the right.
Narrow windows stack these sections. New Settings windows start at 1000 × 760.
Display options and module admission controls remain reachable through named
disclosures; recovery/countdown controls and pending-stop status stay visible.
Actual display snapshots supply the canvas; no prototype sample data enters the app.

Native button tabs retain mouse tracking, focus, accessibility labels, arrow-key
focus navigation and Space activation. Existing first-key and minimum-width tests
were adapted to the production controls. Windows presentation splits existing
controls without changing owner admission or layout operations. Fixtures now include
injected two-display layouts and a 1000 × 760 all-display-features configuration.

`bash test.sh` passed **5,079 isolated checks**, supporting suites and 13 installer
scenarios (`build/open-layout-final.log`). Lint, format and whitespace checks passed.
Release fixtures passed; wide light/dark and narrow light renders were inspected.
Initial compile failure from misplaced section braces was corrected before this run.
The user authorized normal quit, installed-bundle replacement and restart after UI
changes; this does not establish hardware-action or VoiceOver acceptance.

## Minimal popup · 2026-10-22

The popup now shares the Open visual style: quiet Edit header, persistent Settings
footer, neutral feature icons, inset separators, uniform duration presets, larger
active countdowns and a full-width clipboard-history action. Widget Settings links
use small arrow icons with their existing feature-specific accessibility labels.
Widget choices, expanded states, owner callbacks, recovery and measured sizing
remain intact.

`bash test.sh` passed **5,079 isolated checks**, supporting suites and 13 installer
scenarios (`build/popup-open-test.log`). This includes the native first-display-click,
keyboard handoff, popup resize/scroll/settling and session-action regressions.
Pinned lint, format and whitespace checks passed. `--compact-ui-fixtures build`
generated light/dark previews; inactive light, active dark, editing light and
recovery light were inspected. Logs: `build/popup-open-{fixtures,lint,format}.log`.
Restart is authorized; live device operations and VoiceOver remain unverified.

## Window actions palette and quick menu · 2026-10-23

Adds first/middle/last thirds (⌃⌥D/F/G), first/last two-thirds (⌃⌥E/T), and
almost maximize (⌃⌥M, five-percent inset on each side). Existing raw action IDs
and chords remain stable. Odd-sized thirds partition usable bounds without gaps.

⌃⌥⌘Space opens Window actions when global shortcuts are enabled. The extra Command
modifier avoids macOS's next-input-source chord. The popup footer and Windows widget
also open the palette, including when global shortcuts are off. Right-clicking the
menu-bar icon opens a native quick menu: Window actions, Quick actions, Settings,
Quit. Left-click retains the popup.

The native nonactivating panel centers on the target window's screen, with a
system-material translucent background, illustrated actions, key labels and hover
preview. Arrows/Tab select, Return/Space apply, Escape closes. Smaller screens scroll
the grid. Preview animation respects Reduce Motion. The panel captures a target;
changing focus, display geometry, exclusions or admission cannot redirect a click
to another window. Retry/failure messages remain visible without claiming success.

Full `bash test.sh`: **5,141 isolated checks**, supporting suites and **13 installer
scenarios** passed (`build/window-palette-final.log`). Tests cover thirds geometry,
hotkey uniqueness and atomic rollback, captured-target refusal, menu-only action
admission, shared originals, native Right/Return and Escape, and native quick-menu
Settings dispatch. `--window-palette-fixtures build` renders full and constrained
light/dark panels with fake windows; inspected output is in
`build/window-palette-{full,compact}-{light,dark}.png`. Material snapshots do not
prove live desktop compositing. Lint, format and whitespace checks passed.
The final palette chord/label adjustment was followed by focused shortcut checks.
Live global-key delivery, menu-to-app focus return and VoiceOver remain acceptance
gaps pending user use after restart.

## Right-click panel redesign · 2026-10-23

User identified opening/closing stutter and unwanted styling in the small status
menu, not the centered window-action palette. Replaced the `NSMenu.popUp` path with
a retained 304 × 208 nonactivating panel: two action rows, Settings/Quit footer,
system popover material, and no window animations or content-driven resizing.
The panel reuses its hosting tree, installs outside-click observers only while
presented, and removes them on dismissal. Repeated right-click toggles it; left-click
still opens the normal popup. Switching surfaces cancels queued palette presentation.
Quit quiescence dismisses it; all selected commands re-enter host admission.

The user's exact visible hitch was not reproduced or frame-profiled. This removes
the native tracking-menu presentation path; hidden measurements are not proof of
live compositing smoothness. Fifty cached hidden show/dismiss cycles took about
14 ms in the focused run. Regression checks verify stable panel/content identity,
fixed geometry, disabled window animation, unavailable-action traversal, single
dispatch after dismissal, stale input rejection, Escape and popup-to-menu handoff
without new display discovery. Native Settings routing remains covered.

`bash test.sh`: **5,149 isolated checks**, supporting suites and **13 installer
scenarios** passed (`build/status-panel-test.log`). Lint, format and whitespace
passed. `--release-ui-fixtures build` generated inspected light/dark menu snapshots
(`build/status-quick-menu-{light,dark}.png`). Focused logs:
`build/status-panel-presentation.log`, `build/status-panel-fixtures.log`.
Live opening/closing smoothness remains for user confirmation after restart.

## Shortcut-session extraction · 2026-10-22

The candidate-2 working tree based on `ff1e046` moves registration attempt/generation,
retry, stale callback rejection, action outcome state and bounded original-frame
memory into `WindowShortcutSession`. Owner UI properties and `windows.shortcuts`
remain unchanged. Host admission/readiness and explicit queued-layout cancellation
remain in `WindowPositions`; verified writes still use the existing execution module.
See [ownership and primitive registration seam](../architecture/window-execution.md#shortcut-session).

`Tests/WindowShortcutTests.swift` retains the original 36 checks and adds production
session/preset coverage. Every nth-key failure checks exact cleanup order, both
without and with a resource returned on failure. Install failure, successful stop,
retry and idempotent cleanup use the low-level deterministic adapter. Session checks
cover stale callbacks after successful re-registration, failed move/restore memory,
changed-display restore, the 64-frame cap with lexical rather than insertion-order
eviction, stop/restart and invalidation during discovery. Owner checks retain manual
movement superseding queued layouts, closed-host guards and stopped-owner refusal.

No default test installs live global shortcuts. Native Carbon event delivery, real
focus races and multi-app AX movement remain acceptance gaps; no app launch or live
keyboard/window action is authorized by these results.

Validation on this uncommitted candidate-2 tree:

- `bash test.sh`: **5,007 isolated checks**, **10 policy tests in three suites**,
  **160 diagnostics**, **31 reader**, **39 permission-context**, **190 Bluetooth
  observation**, C gesture checks, signed app build, packaging/build fixtures and
  **13 installer scenarios** passed. Includes the original shortcut checks and
  candidate-1 verified-execution tests.
- Pinned lint and format checks, script syntax and `git diff --check` passed.
- Logs: `build/candidate2-test-final.log`, `build/candidate2-lint.log`,
  `build/candidate2-format.log`, `build/candidate2-diff-check.log`.
- The earlier `build/candidate2-test.log` stopped at the compiler's input-modified
  check because a test file was edited during compilation. It is not a full-suite
  pass. The final run used frozen sources. SwiftPM's existing `--build-system native`
  deprecation warnings remain.

No branch, worktree, folder, vendor, alternate build root or commit was created.
Build/signing used the existing `build/` path; no app launch or live registration.
