# Display refresh on presentation · 2026-10-16

Implementation/test revision: **`4e9b8aae181b2a61e7e1ff8fa6f89c2b64f2998d`**,
based on `7cd708a`. **Independent review is required before integration.**
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

**Full lint is not green:** unmodified pinned SwiftLint reports four pre-existing,
baseline-known `AXValue` casts in untouched `WindowPositions.swift`, now at lines
365/428 while the checked-in baseline records 338/401. Neither that source nor
the baseline was changed. All five changed Swift files pass the same pinned
rules. Logs: `build/presentation-refresh-4e9b8aa-{lint,changed-lint}.log`.

Unmodified pinned format-check passes across 60 Swift files, and offline tooling
fixtures pass. In this temporary worktree, SwiftFormat resolves `/private/var` to
`/var`; supplying the logical `/var/.../window-first-click` path as `PWD` to
`bash scripts/dev format-check` and `bash scripts/dev-tools-test.sh` keeps their
configured exclusions effective. No rules or generated sources were rewritten.
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
only their own windows/events and isolated preferences. Live user acceptance,
macOS-version coverage, lint-baseline reconciliation and independent review remain
open. This evidence-only document does not claim a rebuild at its own revision.
