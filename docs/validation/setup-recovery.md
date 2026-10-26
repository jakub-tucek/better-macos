# Setup recovery and lightweight UI host · 2026-10-26

Source: setup-recovery changes based on `dcb2bdf`, committed with this record.

Saved drafts retain their step and recheck current permissions on resume.
Save for later survives window-close handling; Cancel discards the draft.
Navigation and duplicate submission are blocked during application. Windows
shortcut choices are staged before activating a newly enabled owner.
Shortcut registration/discovery/movement failures reach global alerts and the
menu-bar attention state, with Retry and settings actions.

## Evidence

- `build/setup-resume-red.log`: reproduced loss of saved checkpoint position.
- `build/ui-harness-test.log`: 44 native UI checks passed through
  `bash scripts/dev ui-test`, including permission grant/revocation refresh,
  save/resume/cancel, staged settings, Easy setup, applying-state guards,
  failure Review navigation and global shortcut retry.
- `build/setup-harness-test.log`: `tail -n +9 test.sh | bash -e` passed:
  5,363 isolated checks, 44 native UI checks, 10 policy tests/3 suites,
  Bluetooth permission/observation checks, packaging/build and installer fixtures.
  An earlier integration run stopped with exit 31 because the build fixture
  treated the new UI-host entry point as production; its native-UI stub list
  now includes the UI host.
- Pinned lint/format, developer-tool fixtures and whitespace checks passed.

The full entry point remains blocked before these checks by the existing gesture
fixture: `Fixture requires macOS 27 augmented payloads; refusing different payload path.`
The partial pipeline is not a full-suite pass.

## Limits

The approximately 12 MB host uses real SwiftUI screens and in-process native
accessibility actions, with simulated OS boundaries and isolated preferences.
No VM download. Live TCC repair, real global-key conflicts, window movement,
VoiceOver and hardware acceptance remain unverified. The interactive host is
available via `bash scripts/dev ui-test --interactive`.
