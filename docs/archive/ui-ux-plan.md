# UI/UX implementation record

Revision scope: this record retains the agreed design and delivery requirements.
B–D are implemented at the `f359f42` documentation baseline; E native acceptance is
partial. Read imperative/proposed wording below as the original requirements, not
unimplemented feature claims. Later compact-popup and clipboard changes supersede
older dimensions and panel descriptions. See the
[current acceptance matrix](../validation/README.md#acceptance-matrix-and-baseline--2026-10-15),
[compact UI evidence](../validation/compact-ui.md), and
[clipboard UI evidence](../validation/clipboard-ui.md).

Status: production replacement implemented for B–D; parent-session independent review
reports CLEAN at `7e3974cd`. Native acceptance E is partial/open: signed rebuild,
normal quit/relaunch, and Settings window metadata were checked; live AX and capture
inspection were blocked by existing permissions. The first independent review blocked
activation ordering, outcome reporting, and interaction evidence; follow-up fixes
passed the subsequent parent review. The user explicitly waived preview approval and
requested immediate UI replacement. This document retains the agreed requirements;
see [validation evidence and open acceptance checks](../validation/ui-replacement.md).

## Goals

- Open the menu-bar popup and act without navigating through feature cards.
- Configure occasional settings in a full Settings window opened from the gear.
- Choose useful features through a first-run wizard, with short descriptions.
- Customize quick actions as widgets: show, hide, reorder, and choose compact or
  expanded presentation where useful.
- Group settings by purpose. Internal module lifecycles do not dictate navigation.
- Preserve feature behavior, preferences, permissions, and recovery guarantees.

## 1. Two surfaces

### Menu-bar popup: personal quick-action widgets

The popup contains the chosen widgets themselves, not links to another dashboard.
Use a single vertical column, consistent cards, and a scrollable height bounded by
the available screen. Do not add a top-level navigation dropdown or feature grid.

```text
Fix macOS                         Edit   ⚙
┌ Keep awake ───────────────────────────┐
│ 30 min · Display may sleep      Start │
└───────────────────────────────────────┘
┌ Audio ────────────────────────────────┐
│ Output       Headphones             › │
│ Microphone   MacBook microphone     › │
└───────────────────────────────────────┘
┌ Displays ─────────────────────────────┐
│ Dell                              [on]│
│ External                          [on]│
│ Restore windows             Desk   ▶ │
└───────────────────────────────────────┘
┌ Clipboard ────────────────────────────┐
│ Open history                     ⌘⇧V │
└───────────────────────────────────────┘
```

Device selectors may open small contextual pickers. The ban on dropdown navigation
does not prohibit native pickers for selecting an actual device or duration.

#### Initial widget catalog

| Widget | Compact | Expanded |
| --- | --- | --- |
| Keep awake | Start/Stop and remaining time | Duration, display wake, +15 min, active reasons, Resume |
| Audio | Current output; open route picker | Separate output and microphone rows; override status/Resume |
| Displays | Monitor switches | Switches, arrangement shortcut, window-layout restore |
| Window layouts | Restore a chosen default layout | Saved compatible layouts with Restore per row |
| Clipboard | Open history; recording state | Open history plus Pause/Resume and entry count |
| Bluetooth | Chosen devices with connection state/action | Chosen devices plus reconnect pause/status |

Only offer two presentations when they differ usefully. Start with this curated
catalog, not a general widget builder. Compact Clipboard must not preview copied
content; searchable history remains a separate nonactivating panel. Expanded views
must not expose content previews by default either.

Use one instance per widget kind initially. Displays and Window layouts can overlap;
let users hide window-restore controls inside Displays when they add the dedicated
widget. Keep any resulting configuration understandable and persistent.

#### Edit quick actions

- **Edit** enters in-place editing with drag handles, Remove, and **Add widget**.
- Provide Move up/Move down controls for keyboard and accessibility users.
- An add gallery shows a short description and a preview of each widget.
- Each widget offers Compact/Expanded where supported and a direct Settings shortcut.
- Save changes on Done; Cancel discards the edit draft. Offer Restore suggested layout.
- Persist widget kinds, order, presentation, and limited widget-specific choices.
- Hiding/removing a widget never disables its feature, ends an awake session, clears
  history, changes audio, or changes saved preferences.
- Adding a widget never silently activates a disabled feature or requests permission.
  Show **Set up** when needed, linking to the corresponding Settings page.
- For an empty dashboard, show **Add quick actions** and **Run setup**.
- Keep Quit accessible without placing it next to destructive widget actions.

#### Status and safety

Recovery is not a removable widget. Display restore countdowns, pending clipboard
cleanup, and other actionable safety failures remain visible above the widgets.
Offer the recovery action there or a clear link to its Settings page. An active
session still has a reachable Stop action even if its widget is hidden.

Toggles and ordinary actions keep the popup open. Opening the arrangement editor,
Settings, or clipboard history deliberately transfers to the requested surface.
Permission denial, unavailable hardware, busy operations, and empty states must name
the problem and give one next action; do not show a forest of inactive switches.

### Settings: full window

Use a regular, resizable native window rather than a blocking modal. This is the
proposed default; the user has not separately selected modal semantics. Open one
existing window on repeated gear clicks. Preserve its selected group and draft state.
Allow trying quick actions while Settings stays open.

| Group | Contents |
| --- | --- |
| General | Launch at login, updates, diagnostics, Run setup again |
| Quick actions | Widget gallery, ordering, presentation, suggested layout |
| Displays | Monitor switching/safety, arrangement, screen edges, saved window layouts and automatic restoration |
| Sound & connections | Audio preferences/fallbacks, microphone policy, Bluetooth targets and protection |
| Input | Hold-to-quit duration, mouse acceleration/tracking, permission guidance |
| System | Animation controls, menu-bar spacing/hiding, keep-awake app rules/defaults |
| Clipboard | Capture, exclusions, retention, privacy, storage recovery |

Use a sidebar and focused content, with concise feature descriptions and explicit
enable switches inside relevant groups. No separate standalone page just for a
single toggle unless its setup genuinely requires one. Keep advanced choices in
disclosures, not behind multiple nested navigation levels.

Keep saved window layouts simple: Save current layout, named rows with Restore,
and secondary Rename/Delete controls. Add/delete and permission failures explain
what happened without replacing the entire page. Confirm destructive layout removal.

UI grouping must not merge independent module lifecycles. Show per-feature state
inside a group; do not add ambiguous group-wide switches.

## 2. First-run and repeatable setup

### Flow

1. **Welcome.** Explain that Fix macOS applies only selected improvements. Offer
   Set up and Skip for now; skipping opens an empty/safe quick-action home.
2. **Choose improvements.** Group cards by purpose. Each feature has a one-line
   description, a permission/experimental badge where relevant, and an independent
   selection. Selection expresses setup intent, not immediate activation.
3. **Configure selected features.** Show only relevant steps. Combine small settings
   into one group step; give complex Audio/Displays/Clipboard choices enough space.
4. **Permissions.** Request access when that feature needs it, with a reason and
   Open Settings/Retry/Do later. Do not collect every permission up front.
5. **Choose quick actions.** Suggest widgets for selected features. Let users add,
   remove, reorder, and preview them before finishing.
6. **Review and finish.** Summarize requested features, unresolved permissions, and
   side effects. Apply through existing safe feature operations and show per-feature
   results. A failure must not imply that every other feature succeeded or rolled back.

### Descriptions to start from

| Improvement | Description |
| --- | --- |
| Monitor switching | Turn screens on or off without unplugging them. |
| Display arrangement | Arrange screens and bridge differently sized edges. |
| Window positions | Save your window layout and restore it after reconnecting displays. |
| Audio | Choose preferred speakers and microphone independently. |
| Bluetooth reconnect | Reconnect selected devices while protecting other headphones. |
| Keep awake | Prevent idle sleep for a duration or while selected apps run. |
| Hold to quit | Avoid accidental quits by holding ⌘Q before an app closes. |
| Mouse | Adjust supported mouse acceleration and tracking. |
| Animations | Reduce supported system animations. Some effects remain. |
| Menu bar | Compact spacing and hide less-used icons behind a divider. |
| Clipboard | Search recent copies, with optional local disk history. |

### Repeat, cancel, and migration behavior

- **Run setup again** starts from current settings and widget layout. Do not reset
  features or stop ongoing sessions merely by opening it.
- Back preserves the draft. Cancel discards uncommitted choices. Permission grants
  happen in macOS and are not undone by Cancel; explain this where relevant.
- Separate draft configuration from live preview. Initially avoid previews that
  change system settings before Finish. Explicit necessary actions such as opening
  Accessibility settings remain available.
- Keep clipboard capture and disk retention explicit opt-ins, separately explained.
  Do not start recording merely because a Clipboard widget was selected.
- Keep Mouse Apply and monitor safety confirmation explicit. Do not force a display
  change, activate pointer tuning, or start a timed awake session during setup.
- Record completion separately from selections, with a setup version for future
  optional steps. Resume an interrupted draft only after the user chooses to resume.
- Existing installations retain all current feature settings. Offer the wizard from
  Settings or a dismissible invitation, not forced first-run setup after upgrading.
- For existing installations, seed a suggested widget layout once; preserve edits
  and tolerate unknown widget kinds from newer versions without resetting everything.
- If a saved widget refers to an absent device/layout, show a useful unavailable
  state and keep its choice rather than silently redirecting the action.

## 3. Implementation structure

- Keep feature behavior and host transaction admission unchanged. All new actions
  cross existing permission, recovery, and shutdown protections.
- Keep feature state, setup drafts, and widget layout as distinct owned state.
- Use a small, typed widget catalog for identity, presentation, eligibility, and
  Settings destinations. Avoid a plugin framework or configurable arbitrary actions.
- Share feature controls across Settings and setup without duplicating policy.
  Quick widgets expose everyday actions, not the entire configuration view.
- Validate persisted layouts/drafts and migrate them without deleting unrelated
  preferences. Keep ephemeral sessions and sensitive clipboard content out of drafts.
- Route existing launch flags to equivalent quick actions or Settings pages.
- Preserve the nonactivating clipboard panel and normal focus behavior. Do not let
  a setup window accidentally become the target of a quick action intended for
  the previously active app.

## 4. Delivery increments

Each increment gets tests, an independent Sol review, fixes in separate commits,
and follow-up review. Plan with Astra; implement and review with Sol. No parallel
edits to shared navigation files. Independent feature-specific views may proceed
in isolated worktrees after the shared navigation/state decisions settle.

- [ ] **A · Approve visual direction — waived by user for production replacement.** Build a throwaway preview of popup, widget
  editor, grouped Settings, and two wizard steps. Include long device names,
  permission denial, no selected widgets, and recovery countdown examples.
  **Accept:** user approves hierarchy and density before production replacement.
- [x] **B · Full Settings window (implemented; live acceptance partial).** Move configuration out of the popover; establish
  grouped navigation, gear entry, and direct links. Keep current quick controls
  working during this increment.
  **Accept:** every existing setting/recovery action has a reachable destination;
  repeated opening uses one window; current feature settings survive migration.
- [x] **C · Direct quick-action widgets (implemented; live acceptance partial).** Replace the card launcher with a useful
  default widget stack, keeping full controls in Settings. Add persistent show/hide,
  reorder, Compact/Expanded, Edit drafts, Add gallery, and empty state.
  **Accept:** daily actions take no page-navigation step; layout edits survive
  relaunch and do not mutate feature configuration; safety alerts cannot be removed.
- [x] **D · Guided setup (implemented; live acceptance partial).** Add feature selection/descriptions, selected-only setup,
  contextual permissions, widget selection, and per-feature Finish results.
  **Accept:** first-run Skip, repeat setup, Back/Cancel, interrupted drafts, partial
  failure, and denied permissions behave as specified without hidden activation.
- [ ] **E · Native acceptance pass.** Review keyboard/VoiceOver traversal, focus,
  text size, long labels, narrow screens, light/dark appearance, and scroll density.
  Test live safe actions plus existing quit-veto/cancellation and display recovery.
  **Accept:** record evidence and unresolved hardware limitations; do not claim
   usability solely from state-model test counts.
  **2026-10-15 partial evidence:** normal quit/process-exit checks, signed build at
  `7e3974cd`, Settings launch/bounded window metadata, and final popup-route relaunch
  completed. AX returned `apiDisabled`; screen-capture preflight was false. No grants
  were requested. Popup visibility/geometry, Settings gear reuse and content,
  widget/wizard interaction and the manual/hardware criteria remain open; see the
  release-pass section in [validation](../validation/ui-replacement.md).

## 5. Test and review checklist

- Quick action → Settings deep link → return/open behavior, including disabled features.
- Wizard draft/Finish/cancel and permission changes without unintended feature activation.
- Widget add/remove/order/presentation, unknown kinds, missing targets, migration, and restore defaults.
- Runtime session/status updates without resetting Edit drafts or dismissing the popup.
- All actions respect host transaction admission during asynchronous quit.
- Global recovery remains reachable with no widgets or disabled features.
- Clipboard privacy wording and destructive storage controls remain visible and explicit.
- Settings and popup remain usable together; clipboard history preserves destination focus.
- Isolated checks use fake clipboard, devices, assertions, windows, storage, and clocks.
  Live checks are deliberate and documented, not incidental test side effects.
- Run `bash test.sh` and `git diff --check` for each production increment.

## Implementation notes

- `UISurfaces.swift` owns the typed widget catalog, versioned layout store, popup,
  editor/gallery, and grouped Settings view. Unknown widget kinds survive storage.
- `SetupWizard.swift` owns separate configuration and widget drafts, opt-in resume,
  selected-only group steps, permissions, shared controls, review, and results.
- `AppDelegate.swift` owns the two native windows and applies Finish sequentially
  through existing feature operations. Reviewed preferences for new owners are staged
  before any activation; refusals restore only unactivated choices, never recovery
  journals. Audio and awake policy replacement avoids intermediate old-rule effects.
  Admission is checked again at continuations. Typed results come from feature-owned
  failures and readiness, not global error-string comparisons.
- `Dashboard.swift` retains reusable feature configuration views, not the old
  launcher. Window configuration controls are shared with setup. Window actions and
  bindings now also consult host admission, including queued restore steps.
- Fresh installs are detected from established preference families and the legacy
  display domain, not just the new setup completion key. Existing installs retain
  preferences. Quick launch flags use temporary inline widgets without saving them;
  configuration flags deep-link to the corresponding Settings group.
- Sound setup has an explicit read-only device refresh. Bluetooth discovery waits
  for access; requesting permission does not enable reconnect or change routes.
- Mouse proposals remain unapplied until Input → Apply. Named window capture and
  management remain in Displays after setup, explicitly avoiding wizard captures.
- Popup and Settings buttons share tested editor sessions. In-process native-window
  tests suppress presentation/activation while exercising actual host links, window
  reuse, draft preservation, and native close refusal during asynchronous Finish.
  These are not a substitute for live SwiftUI accessibility/button traversal.
- Follow-up review of desktop switching distinguished saved intent from inactive
  runtime state. Setup now installs the reviewed desktop choice before animation
  restoration, always persists Off, and retains requested On while prerequisites
  are pending. Fake-interceptor host regressions failed before the fix and pass
  afterward; ordinary animation Off continues to preserve saved desktop intent.
  Independent follow-up acceptance is still pending.
- Permission-path follow-up makes automatic desktop restoration permission-passive:
  denied access and failed activation retain the pending ticket, later grant restores
  once, and only explicit contextual user actions can request access. Real-host fake
  permission/interceptor tests failed before the fix and pass afterward, including
  repeated refreshes and ordinary animation re-enable after access revocation.

## Original preview proposal

The initial proposal is a regular Settings window, a single-column widget popup,
one instance per widget kind, and a curated catalog. Review default widgets, popup
density, and Compact/Expanded treatments in increment A before finalizing them.
No commitment to third-party feature parity or a general-purpose widget platform.
