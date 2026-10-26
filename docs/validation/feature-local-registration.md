# Feature-local registration and Links UI · 2026-10-26

Validation of the working tree committed with this record, based on `983af9e`:

- `tail -n +9 test.sh | BETTER_MACOS_SIGNING_IDENTITY=- bash -e` passed:
  **5,310 isolated checks**, supporting Bluetooth suites, generator tests,
  Clipboard policy suites, packaging/build fixtures and **13 installer scenarios**.
  Log: `build/feature-local-test.log`.
- Full `BETTER_MACOS_SIGNING_IDENTITY=- bash test.sh` passed its preceding
  compatibility/diagnostic checks, then stopped at the existing gesture fixture:
  `Fixture requires macOS 27 augmented payloads; refusing different payload path.`
  This host runs macOS 26. Log: `build/feature-local-full-test.log`. The partial
  pipeline above does not count as a full-suite pass.
- Pinned lint, format and `git diff --check` passed. Logs:
  `build/feature-local-{lint,format}.log`.
- Hidden-window light/dark fixtures rendered at 680 and 1000 points for Links;
  Battery fixtures covered charging, idle, discharge, assistance, missing readings
  and absent hardware. Links fixtures use an injected browser backend and assert
  no browser open, default-browser request or folder-access request. Each fixture
  registry constructs only its own feature. Log: `build/feature-local-fixtures.log`.
- Focused checks cover preview without discovery/open effects, registered owner
  identity and reuse, disabled/stopped incoming-URL fallback, closed-admission
  rejection of user test opens, widget filtering and saved-order restoration.

Builds use explicitly authorized ad-hoc signing because the configured certificate
is unavailable. Fixture rendering and isolated checks do not establish live
keyboard/VoiceOver, permission-flow, hardware or power-measurement acceptance.
Expanded profile-editor interaction and full native scrolling acceptance remain open.

Architecture and contribution rules: [static registration](../architecture/builtin-registration.md).
