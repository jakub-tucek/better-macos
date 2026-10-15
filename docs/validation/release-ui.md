# Release UI polish validation

2026-10-15 · base `f359f423bd7d3109fe519268776e6ca65d155344`

## Changes and isolated evidence

- Settings and native history Clear share the original confirmation wording.
  Fake clipboard/archive tests invoke the actual Settings callback and native
  Clear button: Cancel preserves entries, pins and disk without writes or change
  callbacks; Confirm clears both stores without changing the clipboard. Closing
  real `HostTransactions` admission while confirmation is pending prevents the
  clear; closed admission also prevents a new prompt.
- Clipboard instructions now distinguish selection from Copy/Return and state
  that copying never pastes. Only the relevant README claims were updated.
- Audio Add is disabled without candidates. Direction-specific fake inventory
  checks distinguish no devices from all available devices already added, and
  exclude opposite-direction devices. Setup points to its existing Refresh
  available devices action. The current-route picker and routing code are unchanged.
- Expanded window-layout Restore buttons name their layout for accessibility,
  matching the existing Settings button labels.

## Reproduced scroll retention

Owned, hidden native `NSHostingView` windows reproduced both navigation failures
in light and dark appearance. Settings Sound → Quick actions and wizard selection
→ Sound configuration retained a content offset of **450 → 450 points**. Both
destinations deliberately have long content, avoiding a false pass from clamping.
The new regression failed before the fix (`release-ui-scroll-red.log`).

Keying the Settings scroll view by category and the wizard scroll view by step
now gives **450 → 0 points** in all four cases. Draft configuration remains in
the existing model, not the recreated scroll surface.

## Commands and artifacts

- `bash test.sh`: **4,016 isolated checks passed**, plus all **7 installer checks**.
- `git diff --check`: passed.
- `build/isolated-tests --release-ui-fixtures <directory>`: early-exit route,
  before the normal suite or runtime host; 20 synthetic PNGs and scroll evidence.
  The normal suite also runs the native navigation regressions without saving PNGs.
- Artifacts under
  `/private/var/folders/01/q8lbfsh16d9bjtl88bpwtr840000gn/T/opencode/`:
  - `release-ui-test.log`
  - `release-ui-scroll-red.log`
  - `release-ui-polish-before/scroll-evidence.txt`: 450 → 450 before scroll fix
  - `release-ui-polish-final/`: final images and 450 → 0 scroll evidence

Visually checked final Settings Clipboard, Audio empty/exhausted/available
candidates (including both directions at the bottom), and wizard empty inventory
and navigation images across light/dark examples. Labels fit, disabled/enabled
Add states match inventory, and wizard Refresh remains visible after navigation.

Only synthetic models, isolated preference suites and fake clipboard/storage
boundaries were used. No live app relaunch/quit, live clipboard/archive access,
device preferences/routes, external window changes, permissions or push. Main's
untracked `RELEASE-CHECKLIST.md` (historical root path, now
[`docs/releases/checklist.md`](../releases/checklist.md)) was neither copied nor staged. Parent review is
still required before integration; these checks do not qualify hardware behavior.
