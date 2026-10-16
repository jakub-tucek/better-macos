# Display refresh on presentation · 2026-10-16

Implementation/test revision: **`4e9b8aae181b2a61e7e1ff8fa6f89c2b64f2998d`**,
based on `7cd708a`. The source-worktree record below predates independent review;
see the [reviewed main integration](#main-integration--2026-10-16) for current status.
This fixes a reproduced display-loading delay, not every reported first-click or
window-activation problem. The production app was not relaunched for this fix.

## Reproduction and diagnosis

Opening the popup previously called `DisplayRefreshGate.requestRefresh()` even
when the display snapshot was already fresh. That immediately published
`displaySettling=true`, disabled display controls, and started another 1.5-second
quiet period. Opening Settings from that popup inherited the settling state.

An isolated native fixture using the production popup/bootstrap path reproduced
approximately **1.57 seconds** of settling with **0.19 ms** of fake discovery.
At 600 ms, the main run loop had delivered 61 timer ticks without running another
snapshot. A first click on Settings' Edit quick actions still worked during that
period: this was not a global input-disable state. Merely becoming active or
opening Settings after settling did not request discovery.

A deliberately injected 300 ms discovery produced a 327 ms main-loop gap,
confirming that discovery is synchronous. Read-only production discovery here
took 0.3–4 ms. These measurements do **not** establish slow discovery in the
user's running app and do not justify moving AppKit/CG work onto a worker thread.
The diagnosis probes and logs are ignored under `build/window-input-diagnosis/`.

## Bounded correction

- [The host](../../Sources/App/AppDelegate.swift) uses the existing `layoutFresh`
  state when presenting the popup. A fresh snapshot is reused without a new
  settling transition or snapshot. Missing/failed snapshots can request a retry;
  presentation during a display operation does not start discovery.
- [The gate](../../Sources/Features/Displays/DisplayRefreshGate.swift) has a
  separate presentation request. It neither restarts a pending quiet period nor
  reenters a running discovery. Explicit refresh requests retain their original
  coalescing/cancellation behavior.
- Initial startup, display-owner activation, actual screen-change notifications,
  watchdog readiness, window-owner wake callbacks and helper completion retain
  deferred refreshes. A display-owner wake observer now also invalidates
  monitor-only configurations, independently of the Window layouts owner. It is
  removed when observation ends or the app terminates. No polling was added.
- Unloading the display owners invalidates the cached freshness flag. A refresh
  cannot mark the layout fresh if another real refresh became pending while it
  was running. Failed initialization/discovery never creates a fresh snapshot.
- Presentation does not cancel pending refreshes, declare the watchdog ready,
  change activation ordering, steal first responder, or remove control/host
  guards. Durable recovery journals remain authoritative, including when the UI
  snapshot is stale. `DisplayController` and its fail-closed journal validation
  are unchanged.

Freshness remains event-driven. Startup, ownership changes, screen notifications,
wake and operation outcomes invalidate it; ordinary focus is not a background
poll. This is not a guarantee of detecting arbitrary suppressed/lost OS
notifications. There is no separate display Refresh button in the current UI;
existing explicit gate requests and setup-device/Mouse refresh actions are not
replaced by the presentation policy.

## Regression seam and red/green result

[The new native tests](../../Tests/PresentationDisplayRefreshTests.swift) use the
same production popup presenter with a fixture-owned invisible anchor, rather
than starting the app/status item/watchdog. Discovery and monitor actions are
injected; preferences use a UUID suite. The real safety owner is never made ready.
No display transaction or global input is posted.

Before the presentation-policy change, the native regression failed on
**the first display-control action**, not merely an `isKeyWindow` assertion
(`build/presentation-refresh-red.log`). With the fix, all **37 checks** pass:

- cold opening retains one initial deferred discovery;
- stable reopening dispatches the first actual display-switch click to its fake
  action, without settling or another snapshot;
- popup → Settings inherits no spurious settle; native sidebar keyboard navigation
  works after mounting/focusing the fixture's own sidebar;
- the actual screen-change observer still disables the switch, and opening during
  that real settle does not extend its deadline;
- failed discovery and cold-owner initialization retry on presentation;
- fake recovery-helper completion, wake without Window layouts, explicit refresh,
  reentrant presentation, request storms and shutdown cancellation retain their
  refresh semantics; presentation with no display owners/recovery does no work.

The popup presenter returns its own view so tests cannot accidentally select a
different fixture's hosting view. The throwing discovery hook models failure;
successful injected refreshes publish freshness just as production refresh does.
Keyboard dispatch is local to the fixture, not live keyboard/VoiceOver acceptance.

## Frozen-revision validation

On macOS **26.6.2 (`25G83`) arm64**, standalone **CLT 27 / Apple Swift 6.4 /
SDK 27.0**, Swift 5 language mode, one complete run passed:

```sh
env -u SDKROOT DEVELOPER_DIR=/Library/Developer/CommandLineTools bash test.sh
```

- **4,633 legacy isolated checks**, including the new 37 and existing 27 native
  Activity scrolling checks; these are included, not additional totals.
- **81 separate diagnostics regressions**, the no-flush/no-synchronous-wait safety
  entry guard, **10 policy tests in 3 suites**, **13 mocked installer scenarios**,
  compiler/build fixtures and real/relocated bundle checks.
- Built `FixMacOSRevision` exactly matches the implementation above. Subsequent
  strict signature verification passed. No version/deployment-target change.

Log: `build/presentation-refresh-4e9b8aa-test.log`. The same built isolated runner
also passes `--presentation-display-refresh-regressions` (37 checks), and
`Tests/activity-scroll-regressions.sh` separately passes its unchanged 27 checks.
Logs: `build/presentation-refresh-4e9b8aa-{focused,scroll}.log`.

**Historical temporary-path lint false positives:** the implementation worktree's
unmodified SwiftLint run reported exactly four baseline-known `AXValue` casts in
untouched `WindowPositions.swift` (current lines 365/428; baseline locations 338/401).
Those reports were initially treated as a baseline issue. Independent review's
byte-compared normal-path snapshot passed all 60 files, and integrated main's
unmodified wrapper also passes below. No source, baseline reconciliation, rule
change or suppression is needed; this was temporary-path baseline matching, not
four new violations. All five changed Swift files also passed. Preserve logs:
`build/presentation-refresh-4e9b8aa-{lint,changed-lint}.log`.

Unmodified pinned format-check passes across 60 Swift files, and offline tooling
fixtures pass. In this temporary worktree, SwiftFormat resolves `/private/var` to
`/var`; supplying the logical `/var/.../window-first-click` path as `PWD` to
`bash scripts/dev format-check` and `bash scripts/dev-tools-test.sh` keeps their
configured exclusions effective. No rules or generated sources were rewritten.
That workaround belongs only to the temporary worktree; normal-path main uses
the unmodified wrapper without a `PWD` override and passes all files/fixtures.
Logs: `build/presentation-refresh-4e9b8aa-{format,tools-logical}.log`.
Shell syntax, CI whitespace fixtures and `git diff --check` passed. CI fixture
log: `build/presentation-refresh-4e9b8aa-ci.log`.

Earlier failures remain in local logs: the expected first-click red result;
`presentation-refresh-green.log` (sidebar not yet mounted); the precommit test/
legacy logs (an experimental callback setup changed unlaunched-host fixtures,
global view lookup selected another fixture, and an experimental direct Settings
refresh reached an uninitialized status item). The final implementation retains
the original startup callback timing and limits presentation-triggered discovery
to the popup/dashboard route. Only the frozen run above is claimed green.

No production app launch/quit/relaunch/install, permission grant, live preference
or device changes, push, tag or publication occurred. Native probes exercised
only their own windows/events and isolated preferences. Live user acceptance
and macOS-version coverage remain open. The original record preceded independent
review; the supplied CLEAN review and normal-path integration checks below supersede
that review/lint caveat, not the historical reproduction or live acceptance limits.
This evidence-only document does not claim a rebuild at its own revision.

## Main integration · 2026-10-16

The parent supplied independent review **CLEAN**, including the first-display-action
negative control, 37 native presentation checks, retained 27 Activity checks and
normal-path 60-file lint verification. Its separate background full run is not
claimed here; the actual integrated-main run below completed independently.

| Reviewed source | Main commit |
| --- | --- |
| `4e9b8aa` — presentation policy and regressions | `ba2db0e` |
| `d30a8e3` — frozen source evidence | `0c596f8` |

Both unique commits integrated without conflicts on clean main `7cd708a`.
At **`0c596f867f1bb981a43ae493e344c091fe9897f1`**, one complete standalone CLT
run passed **4,633 legacy checks**, including **37 presentation** and **27 native
Activity scrolling** assertions (both already inside 4,633), **81 separate diagnostic
regressions** plus safety source guards, **10 policy tests in three suites**, **13
mocked installer scenarios**, compiler/build fixtures and real/relocated-bundle checks.

Log: `build/presentation-refresh-integration-clt.log`; it records HEAD, scoped
standalone CLT 27 / Swift 6.4 / SDK 27.0 compiler/SDK paths and versions, arm64 and
bundle metadata with `SDKROOT` unset. Strict configured-certificate signature,
complete notices, source/built plist lint and metadata passed: the arm64/macOS 15+
bundle embeds the tested revision, version `0.4`, build `4`, SDK 27.0.

**Unmodified normal-path main lint and format-check passed across all 60 files**,
with zero violations/rewrites. Offline tooling and CI whitespace fixtures passed.
No baseline, exclusions, rules, source casts or tooling scripts were changed.
Logs: `build/presentation-refresh-integration-{lint,format,tools,ci}.log`.

The correction only avoids presentation-induced settling when a usable fresh
snapshot exists. Cold/failed retries, genuine display changes, wake and operation
completion still invalidate/defer appropriately. HostTransactions, watchdog admission,
helper execution-time authorization and durable recovery authority remain intact.
This does not establish that every user-reported first-click issue is fixed live.

No production app launch/quit/relaunch/install, live log read, preference/device/
permission change, version bump, push/tag or publication was performed. The parent's
previously reported loaded Activity app was `c76acbf`; building this on-disk bundle
does not replace that process's loaded image. No new process probe or relaunch
approval was assumed. Native live acceptance and supported-OS coverage remain open;
the separate evidence commit does not claim a rebuild at its own revision.

All **15 shell inputs**, **254 local links and 45 fragments across 33 Markdown
documents**, exact-source/guard-preservation assertions and `git diff --check` passed.
The lint baseline and both tools' configurations/scripts are byte-identical to prior main.

## Native fixture coordinate correction · 2026-10-16

Implementation: **`90bb3cc`**, based on main `7e276bc`. Only
`Tests/PresentationDisplayRefreshTests.swift` changes; production sources, suite
wiring and build inputs remain byte-identical to that main revision.

### Reproduction and cause

The integrated visibility full run at `5feb438` **failed**, as recorded in
[its evidence](bluetooth-discovery-visibility.md#completed-main-validation-and-native-test-blocker).
That historical result is not replaced with a pass. Its baseline focused binary
reproduced the exact first-display-click failure in the stable sibling worktree
`/Users/jakubtucek/Projects/others/fix-mac-os-native-first-click-20261016`.
The earlier pre-visibility `52ae53e` reproduction remains valid; this is not evidence
of a Bluetooth regression.

The new probe observed `com.apple.loginwindow` frontmost, an inactive test process
and a non-key popup. Model state was `displaySettling=false`, `monitorBusy=false`,
`displaySupported=true`, two active monitors and one completed snapshot. The fake
monitor callback replaces host dispatch, so HostTransactions could not reject it.
Changing activation policy, calling `finishLaunching`, requesting activation,
pumping events longer, forcing display/layout and changing popup opacity did not
repair the click. No production app or session lock state was changed.

The decisive discrepancy was between logical and WindowServer geometry:

| Observed value | Probe result |
| --- | --- |
| Logical popup frame, AppKit coordinates | `(0, 130, 416, 200)` |
| Own popup's server bounds, CG coordinates | `(224, 1026, 375, 181)` |
| Intended first-switch point in the popup window | `(370, 103)` |
| Dequeued original mouse event | approximately `(161.689, -0.111)` |
| Dequeued server-mapped mouse event | approximately `(370.060, 103.461)` |

The factory-created event initially had the intended logical location. On
`nextEvent`, AppKit converted its unchanged CG screen position through the server's
scale/translation, putting it outside the control. Mapping the fixture's own server
bounds restored the original first native action, without making the app active or
key. This identifies the synthetic-coordinate failure. Loginwindow was observed,
not deliberately locked/unlocked for a causal session-state A/B test.

### Bounded fixture change and negative control

The fixture waits for mounted native scroll content and stable client/server
geometry across run-loop passes rather than a fixed presentation sleep. It queries
only its own popup's window number, maps the intended point through its rendered
server bounds, and posts one local mouse-down/up pair through the unchanged native
event path. Both dequeued locations must remain within two points of the intended
point, allowing integral server-bound rounding; a miss fails, with no click retry.
The first action, genuine-settling suppression and snapshot-count assertions remain.
No direct action invocation, global event posting, watchdog readiness change or
admission bypass was added.
Checking dequeued coordinates prevents a synthetic targeting miss from being
misdiagnosed as an application action/activation failure.

With the final fixture, **five consecutive focused runs pass 43 checks**: the
original 37 plus six native event-delivery/coordinate assertions. Restoring only
the old production `displayRefresh.requestRefresh()` presentation behavior makes
both mouse-coordinate checks pass and then fails the exact original assertion:

```text
FAIL: stable popup's first display-control click acts without an activation/loading click
```

The temporary production-policy edit was restored byte-for-byte before committing.
An earlier negative-control attempt failed the new coordinate assertion while
loading text changed popup height; this prompted the explicit geometry-readiness
condition. It is preserved, not counted as the successful negative control.

Logs under the sibling worktree's ignored `build/`: `baseline.log`,
`retarget.log`, `server.log`, `server-coordinates.log`, `negative.log`,
`negative-stable.log`, `final-focused-{1,2,3,4,5}.log` and `compile-final.log`.
Diagnostic probes are absent from committed code. Main's original full failure
and two tool-timeout logs remain untouched.

Unmodified pinned lint and format-check pass all 63 Swift files; offline tooling,
CI whitespace fixtures, production/input byte comparisons and `git diff --check`
pass. Logs: `build/final-{lint,format,tools,ci}.log`.
Environment: macOS 26.6.2 (`25G83`) arm64, standalone CLT / Swift 6.4 / SDK 27.0,
Swift 5 language mode, command-scoped `DEVELOPER_DIR` and unset `SDKROOT`.
`build/final-shell-environment.log` records the shell/toolchain checks. The new
bundle embeds `90bb3cc`, version `0.4`, build `4`; strict signature and plist checks
pass (`build/final-metadata.log`). It was built, not launched.
One fresh, sequential full run at **`90bb3cc3e88c8ef2188fe2413484683e5af62099`**
completed successfully:

```sh
env -u SDKROOT DEVELOPER_DIR=/Library/Developer/CommandLineTools bash test.sh
```

`build/final-full.log` records **4,771 legacy isolated checks**, including the
**43 presentation** and unchanged **27 native Activity scrolling** checks, already
inside that total. Separately, **81 diagnostics**, their safety-entry source guard,
**114 C safety assertions**, **39 permission-context checks**, **10 policy tests in
3 suites**, **13 mocked installer scenarios**, compiler/build fixtures and
real/relocated-bundle packaging checks pass. No interrupted attempt is counted.
This is branch evidence at the fixture revision, not a new integrated-main result;
the earlier `5feb438` main full run remains failed. No independent review is claimed
for this follow-up, and its evidence-only commit does not claim another rebuild.

This is synthetic native-control validation, not live focus/activation or hardware
acceptance. No production launch/quit/relaunch/install, session unlock, display
helper/device action, Bluetooth operation, TCC grant, live preference change or push
was performed. Production PID 2065 was left running. No concurrent native test
process was observed before the sequential focused/full runs.
