# Integration and compact UI consolidation

> Historical implementation record. The card/navbar/quick-panel navigation and
> 430 × 580 dimensions below predate the replacement UI; they do not describe the
> current app. Use [current acceptance](VALIDATION.md),
> [replacement evidence](UI-REPLACEMENT-VALIDATION.md), and
> [compact-popup evidence](COMPACT-UI-VALIDATION.md). Counts and pending-review
> statements below belong to their recorded revisions. Retain the storage-intent
> table/cases as policy evidence, not proof of current live UI acceptance.

Audio, Clipboard, and Mouse were cherry-picked in their requested order, preserving
individual commits. Existing app-based Keep awake, Windows/display coordination,
QuitGuard's 1–99-second controls, and reversible canceled-quit cleanup remain.

## Panel audit

- Navigation: Quick controls home with direct icon-labelled cards and focused panels;
  separate gear-opened Settings module/setup list. No top-level dropdown or tab strip.
- Shared components: compact `DashboardCard` and right-aligned
  `DashboardSwitchRow`, reusing the accessible `BlueSwitch` implementation.
- Audio: current microphone/output and Resume are quick actions; automatic routing,
  ordered preferences and fallback live in setup. Empty/manual-choice states remain.
- Clipboard: recording, count, Open/Clear, and pending cleanup remain visible;
  retention/exclusions are setup-only, retaining unencrypted-storage warnings.
- Mouse: Apply, Read current, capability failures, and original-value Restore remain
  visible; unsupported wheel controls are collapsed and explicitly unavailable.
- Keep awake: timed/app session controls are quick; app rules/display defaults are setup;
  empty app rules explained, pill symbol
  shared by navigation, panel, and the active menu-bar status item.
- Keyboard: full duration controls, permission settings, and Retry preserved.
- Menu bar: consistent heading/switches; setup instructions and reveal action stay
  visible because they are required to use the feature safely.
- Monitors: countdown/restore, last-display safeguards, layout preview, readiness,
  and empty states remain visible; dangerous-mode choice remains explicit.
- Bluetooth: permission, radio, takeover, reconnect and per-device Connect remain
  primary; protection/output policy is collapsed with headphone detection retained.
- Animations: primary switch/restart warning and busy state remain visible; detailed
  affected effects and desktop-switch settings are collapsed.
- Windows: quick saved-layout Restore; setup has named capture, summaries, Restore,
  Rename/Delete, and automation/exclusions; rename preserves identity,
  geometry, and persisted automatic selection.
- Settings: module switches, login preference, updates, and diagnostics retained.
  Global recovery buttons stay outside feature disclosures and disabled modules.

The native popover remains **430 × 580**. Toggles do not dismiss it. No app was
launched, and there is no claim of visual/live acceptance. Physical device behavior,
destination focus/shortcut behavior, Accessibility interaction, and visual layout
still require manual acceptance. Mouse wheel interception remains blocked because
reliable source attribution is unavailable; no scroll event tap is installed.

## Validation and review status

### Quick controls / Settings replacement

Default launch (including `--show-dashboard` alone) now shows Quick controls home.
The five cards open Monitors, Keep awake, Audio, Clipboard, and Windows quick panels.
Gear opens a separate Settings list with module setup buttons and persistent,
accessible enable switches. Configuration-only features do not appear on quick home.
Quick **Back** returns home; setup **Back** returns Settings; Settings **Back** restores
the prior quick panel/home. Direct **Setup** takes the same return path. Context and
feature identity are separate, so Audio/Windows/etc. can have both views without
cloning their policy controls. Navigation resets scroll position per destination.

Explicit `--show-monitors`, `--show-keep-awake`, `--show-audio`, `--show-clipboard`,
and `--show-windows` select quick panels. `--show-bluetooth`, `--show-spaces`,
`--show-menu-bar`, `--show-keyboard`, and `--show-mouse` select setup panels;
`--show-modules` selects Settings. Permission callbacks retain appropriate setup
entry. Disabled modules remain navigable; pending layout/disabled-display recovery,
countdowns, busy changes and stopping display modules cannot hide display controls.
Global animation/menu-bar/mouse recovery and error actions remain outside panels.

Validation logs: `build/quick-settings-build.log`, `build/quick-settings-test.log`.
Native warnings-as-errors build and full `bash test.sh` run passed: **3,573 isolated
checks and 7 installer scenarios**; `git diff --check` passed. Navigation
regressions cover classification, context transitions, flags, disabled-module return
paths and in-progress display recovery.
No app launch/quit, live clipboard/audio/mouse/window mutation, or push was performed.
Visual, accessibility and physical-device acceptance remain manual. Tool discovery
found no agent-spawning tool; **independent read-only GPT-6.1 Sol review is pending
and must be arranged by the parent**, not inferred from implementer test results.

Review P1 follow-up: a host-side termination barrier now rejects dashboard
mutations (including animation/module transactions, Mouse Apply, Clipboard
recording/configuration, routing, and update installation) during asynchronous
quit. Display/input readiness also prevents queued window/cursor work from
restarting. Existing module/animation/display transactions veto quit before
cleanup starts; final approval checks those transactions again. Cleanup remains
available internally. Cancellation reopens the barrier and requests saved Spaces
restoration; approval keeps it closed through shutdown.

The blocked fake-gesture regression failed before the fix, without releasing
the drain or executing animation preference writes. Real host callbacks now
reject late actions, canceled quit accepts actions again, and retry approves
without a new animation transaction. `bash test.sh`: **458 isolated checks and
7 installer scenarios passed** (`build/review-fix-p1-green.log`). No live
clipboard, routes, window movement, mouse settings, or app relaunch were used.
Independent follow-up review remains the parent's responsibility.

Review P2 follow-up: persistence backends explicitly allow commit-then-throw
failures. Initial enable snapshots any existing archive before writing and tracks
failed saves as pending rollback even while the in-memory persistence switch is
Off. Reconciliation clears a newly created archive or restores preexisting disk
work; failed restoration/cleanup vetoes unload and quit. Successful enable merges
preexisting history rather than overwriting it unseen. Failed retention changes
also remain pending. Explicit Clear supersedes rollback only when the user asks
to discard history; startup recovery continues loading/pruning without silently
deleting saved work.

The commit-then-throw regression failed before the fix. Fake backend tests cover
configuration/memory restoration, real host quit and module-unload vetoes,
preexisting archive preservation, startup reconciliation, retention rollback, and
failed/successful explicit Clear. Final `bash test.sh`: **472 isolated checks and
7 installer scenarios passed** (`build/review-fix-p2-green.log`), with native
SwiftUI built under warnings-as-errors. `git diff --check` passed. These are
implementer-run regressions, not independent review or live acceptance.

Independent follow-up identified a further privacy defect: enable could reload
discarded disk history after a failed Clear. Clear now takes priority before
any enable load/merge, including startup-style loads; failed deletion rejects
enable without reading/saving the archive or changing retention. Metadata
mutations and failed disable cannot replace pending deletion with a save retry.
Only after deletion succeeds may newly captured work be persisted.

The exact commit-then-throw enable → failed Clear → recovered storage → enable
sequence failed before the fix (`build/review-fix-clear-red.log`) and passes
afterward. Regressions cover still-failing deletion, both enable load modes,
ordinary/pinned text and bounded pinned images, repeated disable, metadata
changes, and preserving only post-Clear captures. Previous archive rollback,
startup, and quit/unload regressions remain passing. Latest `bash test.sh`:
**517 isolated checks and 7 installer scenarios passed**
(`build/review-fix-clear-green.log`); `git diff --check` passed. No live clipboard,
app launch/relaunch, device mutation, or push was performed. Parent-arranged
independent rereview is still pending; this is not a self-certified verdict.

### Disable/rollback follow-up and storage intent audit

Independent rereview found that failed Disable could leave both deletion and
archive rollback pending. A completed delete then incorrectly reported clean
while retaining a hidden restore. The exact preexisting pinned archive →
commit-then-throw enable → failed Disable → recovered flush → enable regression
failed before this fix (`build/review-fix-disable-red.log`).

Storage intent is now one enum: idle, save, rollback, startup recovery, or delete.
Clear and Disable replace every prior intent before attempting disk I/O. Disable
immediately revokes persistence, preserves memory, and saves the disabled launch
preference even if deletion fails. Deletion failure/commit-then-throw stays
pending; completed deletion cannot retain rollback/startup work. Clear can still
persist only newly captured post-Clear work when persistence remains enabled.

| Pending intent | Enable | Clear / Disable | Memory edits | Flush / idle retry |
| --- | --- | --- | --- | --- |
| Idle | Load/merge and save; track uncertain failure | Replace with deletion | Save only if persistent | No work |
| Save | Save configured memory; track failure | Replace with deletion | Keep save intent | Save current bounded memory |
| Rollback | Restore original archive before load/merge | Discard rollback; delete | Keep rollback intent | Restore preexisting disk work |
| Startup | Recover load/prune/save before ordinary enable | Discard recovery; delete | Keep recovery; recording remains blocked | Retry startup load/prune/save |
| Delete | Complete deletion first; never load stale disk | Keep deletion; Disable revokes persistence | Keep deletion, preserving new memory | Delete; optionally save only post-Clear work |

Tests exhaust all **3,000 three-action sequences** across rollback, startup,
and active-persistence seeds, followed by recovery/enable/recovery to expose
latent restores. Actions include both enable load modes, Clear, Disable, capture,
pin, unrelated exclusion metadata, failures before commit, commit-then-throw
saves/deletes, and successful recovery. Invariants check that discarded identities
never reappear, clean/off disk is empty after deletion, Disable preserves memory,
Clear discards memory, history remains bounded, and preexisting pinned work
survives when no deliberate deletion occurred. Native module regressions also
cover disabled launch preferences and later explicit re-enable of retained memory.

Latest `bash test.sh`: **3,524 isolated checks and 7 installer scenarios passed**
(`build/review-fix-disable-green.log`); `git diff --check` passed. Earlier
Clear, bounded pinned image, startup, rollback, and host quit/unload regressions
remain passing. No live clipboard/device changes, app launch, or push. These
results are implementer-run; parent-arranged independent rereview remains pending.

Combined integration: 443 isolated checks and 7 installer scenarios passed.
Navigation/Windows policy: 451 isolated checks and 7 installer scenarios passed,
including rename persistence/invalid input/identity preservation, readiness, complete
feature navigation and the shared pill symbol. Native SwiftUI compiles with warnings
as errors. Clipboard/Mouse/Spaces combined quit fixtures use fake storage, mouse,
clipboard and gesture backends; no live device settings/content/routes are accessed.

Integration follow-up: final asynchronous quit completion now rechecks Mouse
restoration as well as Clipboard cleanup. A late Apply during drain cannot approve
quit with owned runtime changes left behind. Injected host regressions cover failed
late restoration veto and successful retry. Final suite: **453 isolated checks and
7 installer scenarios passed**; `git diff --check` passed. This was found during the
implementer's lifecycle audit, not by an independent reviewer.

The adversarial review skill was loaded. This session has no subagent/delegation
tool: tool discovery confirmed only session move/rename and workspace tools, not
agent creation. **Final independent GPT-6.1 Sol integration/UI review is pending.**
Parent session: please arrange a read-only review of the integration and UI range
from `0b8d416` through final HEAD, particularly Mouse Apply during asynchronous
quit, Clipboard cleanup veto, Spaces restoration, permission/recovery visibility,
and compact feature layout. Prior branch CLEAN verdicts are not a final integrated
UI verdict. Do not treat this document as independent acceptance.
