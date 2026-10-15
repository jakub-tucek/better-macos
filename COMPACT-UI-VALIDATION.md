# Compact native popup · 2026-10-15

## Main integration

The four reviewed compact-UI commits were cherry-picked in order onto main
`6878956`, producing `6c97051`, `dbd6255`, `d319b55`, and `d68869c` without conflicts.
The original main working tree was clean.

Actual merged-tree validation at `d68869c`: full `bash test.sh` succeeded with
**3812 isolated checks and seven mocked installer/source-update checks**. This
includes the app build/signature verification and native owned-window popup sizing,
scrolling, settling, and production-action tests using fake backends. Both
`git diff --check 6878956..HEAD` and the documentation working-diff check passed.
Run log:
`/private/var/folders/01/q8lbfsh16d9bjtl88bpwtr840000gn/T/opencode/compact-main-integration-tests.log`.

Integrated-source comparison confirms `HostTransactions.swift`, `SetupWizard.swift`,
`AppModules.swift`, `DisplayArrangementEditor.swift`, `SystemControlLifecycle.swift`,
`WindowPositions.swift`, both clipboard implementation files, and transaction tests
are unchanged. Settings/layout models, the widget editor, and the complete
settings/window-restore views in `UISurfaces.swift` are also byte-for-byte unchanged.

Earlier fixture paths and counts below describe implementation-branch evidence,
not a new live acceptance run on main. No running application is restarted or quit;
no real clipboard/device actions or permission probes are part of this integration.
Live popover anchoring, keyboard/VoiceOver traversal, and device-picker acceptance
remain unverified by this integration.

## Follow-up: content-sized popup

Parent review's fixed-height whitespace gap is addressed. SwiftUI measures the
natural document, header and footer separately; only the scroll viewport is capped.
The popup has a 160-point floor, bounded by available screen space and a 650-point
maximum. Native resizing runs on the next main-queue turn and skips identical sizes;
the measured document is not constrained to the prior viewport height. Native
scrollers retain their own gutter rather than clipping a forced-width document.
Settings windows and their sizing are unchanged.

Full `bash test.sh`: **3812 isolated checks + seven installer checks passed**.
`git diff --check` passes. New tests cover the sizing policy, then exercise the real
SwiftUI content and owned native fixture window: widget add/remove, active/app-rule
and recovery growth, long editor cap, actual native scrolling to offscreen controls,
shrinking/regrowing the available-height bound, restoration to identical empty size,
and absence of further resize events after settling. No live app is launched or quit.

Twenty final native PNGs (light/dark, including long/editor scrolled-to-bottom):
`/private/var/folders/01/q8lbfsh16d9bjtl88bpwtr840000gn/T/opencode/compact-ui-sized-fixtures/`.
Inspected empty, short, long, retry, recovery and editor states. Final dimensions:

| Fixture | Points (width × height) |
| --- | --- |
| Empty | 390 × 178 |
| Short (Keep Awake only) | 390 × 195 |
| Inactive / active widget stack | 390 × 452 / 478 |
| Hidden-widget recovery | 390 × 219 |
| Retained-deadline Retry | 390 × 498 |
| Long / editor (scrollable) | 390 × 580 (fixture screen bound) |

Remaining native acceptance: real status-item popover anchoring across displays,
keyboard/VoiceOver traversal, and device pickers. No live feature controls, permissions,
clipboard, application launch/quit, or main-worktree changes were used for this pass.
Independent follow-up review remains with the parent session.

## Follow-up: explicit retry

Parent review identified that Retry called Start, whose retained-deadline guard
correctly refuses a new session but also prevents renewal recovery. Retry now uses
an explicit `KeepAwakeModule.retry()` reconciliation, through the existing admitted
host callback. It does not reset duration or resume paused app rules.

The new production-action regression failed with the former Start behavior
(`build/retry-red.log`) and passes with explicit Retry (`build/retry-green.log`):
immediate backend attempt after retained-deadline renewal failure, elapsed deadline
preserved on success, paused app intent preserved, and a closed HostTransactions
gate prevents backend attempts even with a live fake timed assertion. The admission
test injects only the transaction coordinator and fake quit actions; it never calls
application quit. Full suite: 3797 isolated checks plus seven installer checks.

Implementation branch: `feat/compact-ui-20261015`, based on `6878956`.
Independent review belongs to the parent session; this is implementation evidence,
not acceptance or a CLEAN review claim.

## Scope

- 390-point popup, native controls, blue feature symbols and existing blue switches,
  separator-based widget sections instead of rounded dashboard cards.
- Keep Awake: one-click 15/30/45/60/120-minute starts; custom 5–1440-minute
  stepper in five-minute increments; second-resolution countdown; End session,
  +15 minutes, display control, app reasons and paused-rule Resume.
- Automatic app configuration remains in Settings. No indefinite or lid-closed
  behavior is offered or implied. Existing callback admission and ownership remain.
- Active Stop stays in global safety UI when editing or when the widget is absent
  or disabled. Protection failures remain globally visible regardless of layout.
- Settings, wizard, widget editing/persistence, and clipboard history are not
  rewritten. Host changes wire popup resizing and the admitted Retry callback;
  the transaction coordinator is injectable for isolated admission regression tests.

## Evidence

- `bash test.sh`: 3793 isolated checks, plus seven install/source-update checks.
  New checks exercise preset ordering and bounds, disabled/stopping refusal,
  countdown/failure/app-only presentation, and production host Start/Extend/Stop
  with fake power assertions, including failed Start.
- `git diff --check` passes.
- Native fixtures: run
  `build/isolated-tests --compact-ui-fixtures <output-directory>`.
  This explicit early-exit route constructs only fresh models, NSHostingViews and
  owned offscreen windows; AppDelegate is never launched. It reads no clipboard,
  requests no permissions, performs no screen capture, and activates no window.
- Ten PNGs cover inactive, active, hidden-widget recovery, editing and empty
  states in light/dark. Output for this run:
  `/private/var/folders/01/q8lbfsh16d9bjtl88bpwtr840000gn/T/opencode/compact-ui-fixtures/`.

## Open visual/acceptance gaps

- Window-local bitmap rendering does not establish live popover placement,
  VoiceOver/keyboard traversal, active-window button emphasis, or actual device
  picker behavior. These require independent native acceptance.
- The original fixed-height whitespace gap is resolved by the content-sizing
  follow-up above. Live popover anchoring remains unverified.
- Settings/editor retain their existing cards; only everyday popup sections change.
- Fragile assumptions for independent review: synchronous duration callbacks remain
  ordered before Start; the existing host continues to reject actions during quit;
  safety recovery is authoritative even when a requested timed deadline survives
  failed assertion acquisition. Existing host regression coverage is retained.
