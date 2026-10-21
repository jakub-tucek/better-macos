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
