# Read-only Battery · 2026-10-26

Implementation based on `ba280fc`: built-in Battery module, System settings,
setup introduction and optional widget. No charge-control API or command is used.

`build/battery-test.log` records 5,202 isolated checks plus supporting suites and
13 installer scenarios, using explicit `BETTER_MACOS_SIGNING_IDENTITY=-`.
Pinned lint/format and whitespace checks passed. Battery tests inject snapshots,
check malformed/missing metrics, distinguish absent hardware and unavailable reads,
and exercise start/stop/restart. Release fixtures cover light/dark Battery details.

The initial build compiled but signing failed because the configured certificate
was unavailable. Two subsequent test runs found catalog expectations that needed
the appended Battery feature/widget IDs and System destination. Existing IDs and
the six suggested widgets remain unchanged; Battery is an optional seventh widget.

A read-only local AppleSmartBattery observation returned 80% charge, 58 cycles,
temperature 3082 (35.05 °C), external power and charging false. No charging settings
were changed. This does not validate all supported hardware or OS versions.

No valid signing identities were available at validation time. Ad-hoc test builds
do not establish installed-app acceptance. Desktop/no-battery behavior, unavailable
metrics and lifecycle transitions have isolated coverage; live VoiceOver and broader
hardware acceptance remain open.
