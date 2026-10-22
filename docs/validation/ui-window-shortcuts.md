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
