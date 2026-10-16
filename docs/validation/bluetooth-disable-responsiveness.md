# Bluetooth disable responsiveness investigation · 2026-10-16

Base: `d7c8da9`. Report: disabling “blueutil” froze UI and required restart.
Initial investigation did not know the exact control or app-only versus
whole-input scope. The later clarification below supersedes that initial scope.
**Incident root cause remains unconfirmed. No production fix was made.**

## Clarified trigger: revoke blueutil Bluetooth permission

The user subsequently clarified: blueutil's permission was disabled in macOS
Settings, then the entire desktop could not be clicked and required restart.
This was **not** a feature toggle. The host-toggle checks below do not reproduce
that incident. No permission was revoked again during this investigation.

### Primary-source facts

- [blueutil 2.14.0 source](https://github.com/toy/blueutil/blob/60d8411fa3f9968ab6f05e198b486fe89961e18f/blueutil.m)
  (`v2.14.0` resolves to `60d8411fa3f9968ab6f05e198b486fe89961e18f`):
  `BTPowerState` aliases private `IOBluetoothPreferenceGetControllerPowerState`.
  A getter command prints its integer and returns success without a separate
  authorization check. `BTSetParamState` polls up to ten seconds and returns
  `EX_TEMPFAIL` (75) if the requested power state never appears. Exit 75 is a
  timeout, **not proof of permission denial**.
- The same source installs `handle_abort` for SIGABRT; it prints that absent
  Bluetooth access **may** be the cause and exits `128 + SIGABRT` (134).
  There is no explicit denied-authorization result for this app to trust.
  Paired-device JSON uses the IOBluetooth result without a distinct access-status
  field. Zero power/empty inventory alone cannot distinguish every possible
  backend access failure from a legitimate off/empty state.
- [Apple's authorization documentation](https://docs.developer.apple.com/tutorials/data/documentation/corebluetooth/cbmanager/authorization-swift.type.property.md)
  describes checking **the app's** Core Bluetooth authorization. It does not
  provide an API for querying an arbitrary external executable's authorization.
  The app's allowed result therefore does not independently prove helper access.
- Apple's DTS [responsible-process discussion](https://developer.apple.com/forums/thread/731504)
  describes system-managed responsibility and TCC attribution, with no general
  API for managing it. Search supplied the DTS answer; direct forum retrieval was
  blocked by Apple's browser verification. Do not assume the helper's permission
  is always independent, always inherited, or that toggling its listed entry
  necessarily kills/suspends this parent. This investigation found no verified
  Apple contract for the precise macOS revocation effect in this incident.

### Focused offline permission-context loop

`DEVELOPER_DIR=/Library/Developer/CommandLineTools bash Tests/bluetooth-permission-regressions.sh`
passed **29 checks**. The runner compiles the unchanged production Bluetooth and
Audio owners, CommandRunner, diagnostics and ActivityJournal. Compile-only
`ToggleError`/`FeatureSetupOutcome` seams avoid constructing the app/display host;
the audio owner is not instantiated. Parent authorization is injected. A
temporary fake executable emits synthetic results, not real TCC effects.
The subprocess runner has a 30-second external deadline; blocked fixture helpers
self-expire. No installed blueutil, Core Bluetooth manager, live audio backend,
input tap or service is invoked. Log: `build/permission-context-tests.log`.

Observed:

1. Parent allowed + child exit 134 stays a helper error, not invented parent
   denial. Signals and exit 75 likewise complete off-main without recursive retry.
2. A gate releases an active command into exit 134 or self-SIGTERM. Both finish
   once, issue no next observation command, and leave the main queue responsive.
3. Persistent helper failure launches once initially and once at the five-second
   poll. There is no error-driven hot loop. This does not prove an OS permission
   prompt cannot recur on each scheduled launch.
4. A helper exits while a background descendant retains stdout/stderr. The worker
   stays busy, 100 poll requests launch nothing, and main-queue heartbeat still
   runs. Stop completion fires exactly once only after real pipe drain.
5. Injecting parent denial blocks new helper launches. This does not simulate
   responsibility reassignment, TCC suspension, or hardware-input disconnect.
6. **Confirmed secondary presentation bug:** after successful radio-off discovery,
   the next synthetic helper failure sets `status`/`lastError` to exit 134, but
   `reconnectSummary` still says “Bluetooth is off — turn the radio on first”.
   The cached radio-off branch precedes the newer error branch. This is a stale
   summary, not a demonstrated permission-denial classifier or desktop-freeze cause.

Narrow proposal, **not implemented**: prioritize the latest observation error
over cached radio-off guidance. Keep `permissionRequired` tied to actual parent
authorization; do not relabel 75/134 as confirmed denial, automatically power on,
grant permission, reset TCC, or abandon active-command ownership. The diagnostic
fixture currently asserts the reproduced stale summary; flip that assertion to
the desired behavior only when implementing the independently reviewed fix.

### Remaining incident hypotheses and safe diagnostic plan

Ranked investigative leads after the offline evidence, before any production fix:

1. **Input-service/hardware loss after the permission change.** Prediction: desktop
   animations/main callbacks continue, Bluetooth input stops, built-in/USB input
   still works. Loss of all input, including built-in input, weakens this lead.
2. **TCC responsible-process suspension/termination or OS-service stall.** Prediction:
   existing process/crash events or a contemporaneous stack sample show that
   boundary. An uninterrupted parent event stream weakens parent termination;
   helper exit alone does not establish an OS-wide stall.
3. **Repeated scheduled helper launches and permission UI interference.** Prediction:
   starts continue at roughly five-second intervals with visible permission UI.
   No corresponding starts weakens it. Offline tests rule out a tight error retry
   loop, not TCC UI behavior.
4. **Coincident input/gesture latch.** Prediction: built-in input also fails while
   parent callbacks continue and Bluetooth helper results do not correlate.
   Separate gesture investigation owns that code; no vendor/input changes here.

Do not ask the user to revoke permission again. First clarify whether the pointer
still moved, whether clicks failed everywhere, whether built-in/USB input worked,
and whether keyboard shortcuts/clock animations continued. Correlate the already
authorized sanitized app logs and existing crash reports for the incident window,
including compiled revision/session and command start/finish IDs. A returned
main-queue callback is evidence against continuous parent main-thread deadlock
at that moment, not proof of healthy global input. Only if separately authorized,
capture a future naturally occurring incident's read-only process stacks and
system diagnostics. Do not inspect private TCC databases or reset permissions.

No broader suite, app build/relaunch, hardware acceptance or independent review
was performed for this clarified scope. Incident causality remains open.

## Initial host-toggle investigation (superseded incident scope)

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

Initial ranked falsifiable leads: (1) loaded revision/shared synchronous display discovery,
(2) radio/input loss with healthy app heartbeat, (3) off-main helper/pipe drain
with healthy heartbeat but persistent stopping. Ranking is investigative, not a
diagnosis. At that stage the exact clicked control, event sequence, loaded revision and
whether a built-in/USB pointer or keyboard still worked were unknown. An action-time main-thread
sample would distinguish an actual run-loop stall from lost Bluetooth input.

Independent review required before merge. No changes were merged or published.
