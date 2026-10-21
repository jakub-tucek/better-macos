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
