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

## Direct details and power flow · 2026-10-26

Follow-up based on `6ff4146`. The widget header routed to the System group, whose
first controls were unrelated to Battery. `build/battery-details-red.log` records
the failing production host-route assertion. Battery now owns a dedicated Settings
category; the header arrow, explicit Battery details action and `--show-battery`
launch route target it. Feature-specific destinations avoid relying on a feature's
position inside a shared scrolling category.

The read-only backend decodes SystemPowerIn/SystemLoad as milliwatts and battery
voltage/current as millivolts/milliamps. Signed current handles unsigned IOKit
two's-complement values. Adapter rating is displayed separately, never substituted
for live input. Missing/invalid data and negative derived consumption stay unknown;
unplugged snapshots ignore stale adapter telemetry. Refresh interval is five seconds.

`build/battery-details-test.log`: **5,215 isolated checks**, supporting suites and
13 installer scenarios passed with explicit ad-hoc signing. Pinned lint/format and
whitespace checks passed. Regression coverage includes the host destination, launch
flag, charging, discharging, adapter-assisted discharge, telemetry units, missing
values, rating-only input and contradictory power balance.

Light/dark fixtures include 680/1000-point Settings widths, charge/discharge,
adapter-assisted discharge, absent hardware and unavailable metrics. Inspected
snapshots show visible Battery navigation, power cards and wrapped detail text;
the narrow view scrolls for further details. A local read-only observation reported
20.492 W input/system load, a separate 65 W adapter rating and zero battery current.
This is not wall-meter calibration or cross-model acceptance. Live VoiceOver and
unplug/replug behavior still require hardware acceptance.
