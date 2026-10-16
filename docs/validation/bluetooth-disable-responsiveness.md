# Bluetooth disable responsiveness investigation · 2026-10-16

Base: `d7c8da9`. Report: disabling “blueutil” froze UI and required restart.
The exact UI action, loaded revision and app-only versus whole-input scope are
unknown. **Incident root cause remains unconfirmed. No production fix was made.**

## Deterministic isolated check

`Tests/BluetoothErrorRecoveryTests.swift` now exercises actual `AppDelegate`
dashboard callbacks, `BluetoothModule`, and `CommandRunner` with a temporary
executable named `blueutil`. The helper blocks behind a file gate, self-expires,
and never invokes installed Bluetooth tools. While blocked, three repeated cycles
exercise automatic reconnection off, target uncheck, module disable, rapid
re-enable refusal and the actual native termination-decision callback. Main-queue
heartbeats must return within 250 ms. Host stopping state must persist until
the actual worker completes, and late results must not revive the disabled owner.

A separate explicit legacy-takeover callback uses an injected slow command instead
of launchctl. Disabling during takeover remains responsive; its late completion
cannot commit takeover or enable automatic reconnection.

The full isolated native executable passed **4,704 checks**, including **71 new
checks**, after compilation with standalone CLT, Swift 5 mode, warnings-as-errors,
arm64/macOS 15 target. The first run before adding takeover passed 4,700 checks.
Both runs had an external 100-second subprocess deadline; the fixture helper has
its own finite gate. Log: `build/drain-tests.log` (ignored).

Compilation reused the unchanged main checkout's existing C objects and static
ClipboardPolicy archive/module. This was **not** a full `test.sh`, packaging,
fresh dependency build, lint/format or independent review run. No main app build,
app launch/quit, radio mutation, launchctl, TCC or live preference write occurred.
Existing suite read-only capability checks remain read-only. Native run-loop
coverage is not live hardware or incident acceptance.

## Source trace and remaining leads

- Automatic-off and target-uncheck cancel an in-memory token. They do not join
  a queue or wait for a subprocess. Poll/reconnect, manual connection/power-on,
  and legacy takeover run on the Bluetooth serial utility queue.
- `stop(completion:)` cancels further policy effects and retains busy ownership
  until the main-queue completion. The host retains the owner and stopping state,
  refuses re-enable during drain, and vetoes quit while a module is stopping.
- `CommandRunner` waits for process exit and both pipe readers on its worker.
  Timeout sends terminate, then SIGKILL after one second if still running.
  An inherited pipe held open by a descendant can still stall `readers.wait()`;
  this would explain stuck stopping/quit refusal, **not establish main-loop freeze**.
- Bluetooth does not expose radio-off. Real radio loss could disconnect Bluetooth
  input while leaving the application's run loop healthy; no hardware test was run.
- Module-choice reconciliation also requests shared display refresh when display
  features/recovery are active. These tests deliberately have those owners off.
  Slow display/other shared owners therefore remain outside this reproduction;
  old loaded builds and action-time main-thread stacks must be checked before
  attributing the incident to Bluetooth cancellation.

Ranked falsifiable leads: (1) loaded revision/shared synchronous display discovery,
(2) radio/input loss with healthy app heartbeat, (3) off-main helper/pipe drain
with healthy heartbeat but persistent stopping. Ranking is investigative, not a
diagnosis. Need the exact clicked control, event sequence, loaded revision and
whether a built-in/USB pointer or keyboard still worked. An action-time main-thread
sample would distinguish an actual run-loop stall from lost Bluetooth input.

Independent review required before merge. No changes were merged or published.
