# Integration and compact UI consolidation

Audio, Clipboard, and Mouse were cherry-picked in their requested order, preserving
individual commits. Existing app-based Keep awake, Windows/display coordination,
QuitGuard's 1–99-second controls, and reversible canceled-quit cleanup remain.

## Panel audit

- Navigation: icon-labelled feature chooser, including Mouse; Settings behind the
  gear, returning to the previously selected feature. No crowded tab strip.
- Shared components: compact `DashboardCard` and right-aligned
  `DashboardSwitchRow`, reusing the accessible `BlueSwitch` implementation.
- Audio: current microphone/output and Resume remain visible; ordered preferences
  and fallback are disclosures. Empty-device and manual-choice states are explicit.
- Clipboard: recording, count, Open/Clear, and pending cleanup remain visible;
  retention/exclusions are collapsed, retaining unencrypted-storage warnings.
- Mouse: Apply, Read current, capability failures, and original-value Restore remain
  visible; unsupported wheel controls are collapsed and explicitly unavailable.
- Keep awake: timed/app controls preserved, empty app rules explained, pill symbol
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
- Windows: named capture, saved layout summaries, per-row Restore, secondary
  Rename/Delete, and advanced automation/exclusions; rename preserves identity,
  geometry, and persisted automatic selection.
- Settings: module switches, login preference, updates, and diagnostics retained.
  Global recovery buttons stay outside feature disclosures and disabled modules.

The native popover remains **430 × 580**. Toggles do not dismiss it. No app was
launched, and there is no claim of visual/live acceptance. Physical device behavior,
destination focus/shortcut behavior, Accessibility interaction, and visual layout
still require manual acceptance. Mouse wheel interception remains blocked because
reliable source attribution is unavailable; no scroll event tap is installed.

## Validation and review status

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
