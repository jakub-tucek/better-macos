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

## Links bulk editing

The later bulk-edit implementation passed **5,326 isolated checks**, supporting
suites and 13 installer scenarios through the same partial pipeline above.
`build/links-bulk-test.log` records the run; `links-bulk-{lint,format,fixtures}.log`
record pinned checks and hidden-window rendering. Focused cases cover selected-only
edits, stable IDs/order, append priority, persistence, duplicate handling, invalid
line rejection, CRLF line numbers, host admission and absence of browser effects.
The 680-point rule list was inspected; expanded importer/selection interaction and
VoiceOver remain native acceptance gaps. The existing full-suite OS blocker remains.

## Accessibility status and text rules

The bulk-edit UI above was replaced by one staged text editor at user request.
Existing rules round-trip through `kind: match -> destination`, including disabled
rules, profiles, unavailable saved targets and quoted special characters. Validation
blocks whole saves on malformed lines/unknown destinations; concurrent edits and
closed host admission also refuse the save. Existing persistence remains unchanged.

An injected host regression first failed because enabling screen-edge matching did
not open Accessibility settings (`build/screen-edge-access-red.log`). The fix adds
a denied-access status, explicit Settings/recheck actions, foreground rechecking
and a warning status icon that takes priority over Keep awake. Permission recovery
still respects watchdog/display readiness and preserves unrelated errors.

The partial pipeline passed **5,330 isolated checks**, supporting suites, packaging/
build fixtures and 13 installer scenarios (`build/access-text-test.log`). Pinned
lint/format and whitespace checks passed. Light/dark fixtures rendered; the narrow
Links editor and 420-point access warning were inspected. Logs:
`build/access-text-{lint,format,fixtures,fixture-build}.log`.

The installed ad-hoc binary's command-line permission probe returned not granted;
this is not proof of the GUI process's TCC attribution or the cause of a stale grant.
No macOS permission entry was reset or changed by these checks. Live grant repair,
event-tap activation, keyboard/VoiceOver acceptance and the existing macOS 27
full-suite gesture gate remain open.

## Hold to quit permission recovery

The owner previously saved `quitGuard.enabled` only after listener startup, losing
the requested On choice when permission was denied. Foreground activation also
had no Hold to quit retry. `build/quit-access-red.log` reproduces the lost request.
The owner now saves intent before activation; the host opens Accessibility on an
explicit blocked enable and retries the retained owner on return. Dedicated status
distinguishes permission denial from listener failure and preserves unrelated errors.

`build/quit-access-test.log` passed **5,338 isolated checks**, supporting suites,
build/packaging fixtures and 13 installer scenarios through the partial pipeline.
Injected permission checks and tap factories verify denied/granted transitions,
saved intent, automatic host retry, explicit disable, and warning ownership without
installing a real event tap. An intermediate run exposed unnecessary runtime-status
writes from foreground checks with no owner; the retry now requires a loaded owner,
and the existing login preference-immutability regression passes. Pinned lint,
format and whitespace checks passed. Native TCC grant repair and keyboard listener
acceptance remain unverified; the existing full-suite OS blocker remains.
