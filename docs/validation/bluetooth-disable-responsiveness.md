# Bluetooth disable responsiveness investigation · 2026-10-16

Base: `d7c8da9`. Report: disabling “blueutil” froze UI and required restart.
Initial investigation did not know the exact control or app-only versus
whole-input scope. The later clarification below supersedes that initial scope.
**Incident root cause remains unconfirmed.** A later, separately authorized
secondary presentation correction is recorded below; it is not a desktop-freeze fix.

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

Initial narrow proposal, **not implemented at `af0517f`**: prioritize the latest observation error
over cached radio-off guidance. Keep `permissionRequired` tied to actual parent
authorization; do not relabel 75/134 as confirmed denial, automatically power on,
grant permission, reset TCC, or abandon active-command ownership. The diagnostic
fixture at that revision asserts the reproduced stale summary; flip that assertion to
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

At `af0517f`, no broader suite, app build/relaunch, hardware acceptance or independent
review was performed for this clarified scope. Incident causality remains open.

## Secondary presentation correction (not a desktop-freeze fix)

The user separately authorized correcting the reproduced stale summary.
`3d77b0c` introduces explicit stale-observation presentation in the owner and
projects it through the actual host/model into Settings. A failed initial
discovery now says “Could not read Bluetooth status” with the existing error
detail and warns that cached device information may be out of date. Cached
devices, targets, preferences and last known radio state remain intact. Stale
state suppresses the radio-off power-on instruction and the empty-inventory
instruction. Actual parent authorization still owns permission-required UI.

`c8a44b4` distinguishes initial radio/inventory discovery failures from later
automatic connection/routing errors. The latter retain their existing error
meaning instead of acquiring a misleading status-read label. Error classification
uses a typed discovery wrapper, not exit code or error-text comparison. The
underlying localized detail is preserved. Operational diagnostic event fields and
redaction are unchanged; the existing local UI snapshot carries the corrected summary.

A successful fresh device snapshot clears stale-observation state. Existing
manual-error publication UUIDs remain host-owned: observation success never clears
the global manual-action banner; verified retry of the same manual action still
uses the existing ownership rules. No subprocess timeout/drain, inherited-pipe
handling, automatic radio action, authorization policy, poll cadence or vendor
gesture code changed.

The focused test was first changed to require the corrected summary and failed
before the fix (`build/permission-presentation-red.log`). A follow-up regression
then reproduced mislabeling of automatic connection failure before the typed
discovery correction (`build/permission-classification-red.log`). Both pass after
the corrections. `test.sh` now runs the focused executable by default, with no
deliberately failing assertion. Its compiler-only nested build fixture mocks this
auxiliary suite exactly as it mocks the other auxiliary suites; the real top-level
suite remains enabled.

The first complete run at `3d77b0c` stopped with exit 32 in `Tests/build.sh`:
its mock compiler was inadvertently given the new focused-suite input list.
All prior focused checks, app build and real/relocated packaging had passed;
that partial run is **not** full-suite success. The explicit mock-list addition
in `c8a44b4` corrects that fixture integration.

Unmodified normal-path lint/format/tooling passed at both implementation commits
in `/Users/jakubtucek/Projects/others/fix-mac-os-bluetooth-validation`, a detached
validation worktree. Temp-path lint initially reported the four unchanged
WindowPositions forced casts despite their baseline; temp-path tooling also
failed path-based exclusion fixtures. Neither baseline nor config was changed.
These historical failures remain in `build/bluetooth-presentation-{lint,tools}.log`
in the implementation worktree.

### Frozen secondary-fix validation

At **`c8a44b450e58f61b1c65dfcb065186d82a74eab9`**, the complete command
`MAC_UTILS_SIGNING_IDENTITY=- DEVELOPER_DIR=/Library/Developer/CommandLineTools bash test.sh`
passed:

- **4,731 legacy isolated checks**, including the actual-host failure/recovery
  regressions and the earlier blocked-disable/takeover checks.
- **32 separate focused permission-context checks** and **81 separate diagnostic
  review checks**, plus the safety-entry source guard. These are not added to
  the legacy count.
- **10 Swift Testing policy tests in three suites**, **13 mocked installer
  scenarios**, state compiler checks, build/publication failure fixtures and
  real/relocated signed-bundle notices/dependency/metadata checks.

Log: `build/bluetooth-presentation-c8a44b4-full.log` in the implementation
worktree. The built plist embeds the exact revision above; an additional strict
`codesign --verify --deep --strict` passed without launching the bundle.
Standalone CLT used Apple Swift 6.4 (`swiftlang-6.4.0.34.1`) / SDK 27.0, Swift 5
language mode, arm64/macOS 15 target.

Unmodified normal-path lint and format passed across **62 Swift files** at the
same revision. Offline tooling and CI whitespace fixtures, committed-range
whitespace from `d7c8da9` to that revision, shell syntax and `git diff --check`
passed. Normal-path logs:
`build/bluetooth-presentation-c8a44b4-{lint,format,tools}.log` in the detached
validation worktree above. CI/range logs are
`build/bluetooth-presentation-c8a44b4-{ci,range}.log` in the implementation worktree.
Hosted CI was not run. No lint baseline/config or CI workflow was altered.

No production app was launched, installed or quit; no live permission, device,
input, audio, clipboard, system-preference or launchctl mutation was performed.
The isolated suite mounts fixture-owned native windows and retains its existing
read-only capability checks. Tests use isolated defaults, injected backends and
temporary helper executables. No real permission was revoked again. Nothing was
merged, pushed or published. This documentation commit does not claim a fresh
bundle built at its own revision.

Independent review remains required before merge. This correction neither
reproduces nor fixes whole-desktop loss of clicks after permission revocation.

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
