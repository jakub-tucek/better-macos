# Compact native popup · 2026-10-15

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
  rewritten. `AppDelegate.swift` changes only the two native popover widths.

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
- Popup retains the existing bounded fixed-height scroll surface, so small widget
  selections leave blank space above Quit. Content-sized popover height is not
  implemented here.
- Settings/editor retain their existing cards; only everyday popup sections change.
- Fragile assumptions for independent review: synchronous duration callbacks remain
  ordered before Start; the existing host continues to reject actions during quit;
  safety recovery is authoritative even when a requested timed deadline survives
  failed assertion acquisition. Existing host regression coverage is retained.
