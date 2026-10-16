# Bluetooth observation, separate from control

## Scope

Observation-only correction based on `52ae53e`. This does not establish the cause
of the live helper/native disagreement or qualify Bluetooth control on macOS 26.
No permission reset, helper replacement, automatic power action or control API
fallback is introduced. Independent review remains required before merge.

The reported live evidence was controller on / six known devices in
`system_profiler`, while the GUI's blueutil queries reported off / empty. Parent
authorization was allowed. That is contradictory observation, not proof of a TCC
denial, stale preferences, pairing failure or a physically off controller.

## Owners and evidence

- `BluetoothBackend` still owns blueutil control and its existing verification.
  Primary on/nonempty reads take the existing path without running a profiler.
- `BluetoothObservationService` compares suspicious off, empty or failed reads
  with one read-only `system_profiler SPBluetoothDataType -json -detailLevel basic
  -timeout 8` snapshot. Backend copies share the service's cache/in-flight state.
- `BluetoothReadback` keeps helper power/inventory, native power/inventory,
  source, conflict and freshness distinct. Unknown is never off. A failed or
  incomplete comparison blocks control; it does not turn native inventory into
  a usable control backend.
- `BluetoothModule.devices` and `radioPoweredOn` remain primary control evidence.
  `displayedDevices` / `displayedRadioPoweredOn` are presentation only. Native
  devices never enter reconnect, audio protection, output routing, or mutation
  verification. The owner rejects manual requests and queued requests while
  controls are unavailable, even from non-UI callers. Production controls also
  remain blocked before the initial comparison completes. Host admission remains
  unchanged.
- Settings and both widget sizes show source and conflict. The reported case
  reads: “macOS reports Bluetooth on; helper reports off. Device controls
  unavailable.” Native-on evidence never causes `blueutil --power 1`.

Normal coherent primary behavior is retained. A coherent off/empty comparison
can still expose the existing explicit power-on action. An already-admitted
manual mutation invalidates the old native snapshot; only the original helper
path verifies that mutation. Replacing that control path is separate work.

## Parser contract and limits

The command/JSON interface is documented by `system_profiler(8)`; Bluetooth field
names are a version-sensitive schema, not an Apple compatibility guarantee.
The narrow parser accepts one controller, explicit `attrib_on` / `attrib_off`,
and explicit connected/disconnected arrays. Missing controller, ambiguous
controllers, adapter error fields, malformed types and unknown power values
cannot imply off. Missing arrays cannot imply empty. Device identity requires a
valid twelve-hex address, accepting ordinary colon/hyphen forms for comparison.
Duplicate identities, even with identical state, reject the inventory rather
than selecting an arbitrary row. Names are display data, never identity.

`mini` can show controller state/counts but omits device addresses on the observed
OS. It cannot resolve saved targets. `basic` is necessary for identity matching.
Only name/address/connected survive parsing; other device metadata is discarded.
Canonical comparisons preserve saved preference spelling and values; native IDs
are not migrated into stored target choices. Missing-target counts compare
canonical identity, not formatting.

The command can return partial reports at exit zero. Explicit structure and
types are required; a partial report cannot replace a complete cached snapshot.
No parser can detect a silently omitted device in an otherwise valid report.
Unknown schema versions fail conservatively, rather than claiming native API
or hardware acceptance.

## Worker lifetime and cache

All production subprocess work runs on the existing feature utility queue.
In-flight requests coalesce without synchronously waiting on another caller.
Complete snapshots have a 30-second monotonic TTL. Failed attempts back off for
30 seconds. Failures/partial results retain the previous complete snapshot and
its timestamp. Stale data can be viewed but cannot grant control/audio readiness.
Cancellation does not cache a late result; feature delivery checks the cycle
token and stopped state before publishing. Stop waits for the active feature
cycle through its existing completion path.

`BluetoothProfilerProcess` is dedicated to this observation, not a rewrite of
`CommandRunner`. It uses argument arrays, nonblocking pipe reads and a combined
1 MiB output budget. It checks cancellation/deadline between bounded reads.
The application deadline is 10 seconds, including pipe EOF waits; termination
gets 150 ms before SIGKILL of only the still-running owned subprocess. Pipe
holders cannot leave blocked reader workers. Read handles close on completion;
stderr contents and subprocess error text never escape this boundary.

Foundation owns asynchronous child reaping. After forced termination, worker
cleanup has a one-second ceiling; an OS-delayed exit can outlive the observation
callback while Foundation retains reaping ownership. This is not a guarantee
against an unkillable kernel-stalled child. No descendant process is killed.

## Privacy and validation

Structured observation events contain only source, conflict, freshness,
controller state, count, duration, timeout and closed issue values. No names,
addresses, raw JSON, stderr or localized errors are logged. Native display
metadata does not enter the existing persisted helper snapshot device rows.
An observation never resolves the host's UUID-owned manual-action error.

Parallel copy/diagnostic UI work should consume the typed `readback` and retain
both helper and native provenance, not reinterpret the existing persisted
snapshot's `radioOn` field as native power. That legacy field and its device rows
remain helper evidence; added source/conflict/control-availability fields explain
the comparison. Preserve both branches' `AppDelegate` model projections and
Settings/widget controls when integrating. No competing copy action is added here.

`Tests/bluetooth-observation-regressions.sh` uses injected JSON, clocks,
read/control backends, diagnostic sinks and temporary executable fixtures. It
tests the exact off/empty versus on/six/two-saved-target case with zero mutation
commands; parser rejection, unknown/partial/mini data; cache/backoff/coalescing;
late cancellation/stop; bounded child/pipe/output failure; and privacy sentinels.
The full runner additionally exercises actual host/model projection and preserves
the independent manual-error publication UUID. Temporary helpers do not invoke
installed blueutil or the real system profiler. These checks do not establish
live control, permission-context cause, or hardware acceptance.

## Source references

- [blueutil v2.14.0 source](https://github.com/toy/blueutil/blob/v2.14.0/blueutil.m),
  tag commit `60d8411fa3f9968ab6f05e198b486fe89961e18f`: private preference power
  getter/setter and a separate experimental profiler paired-device path. Its
  environment flag does not replace power reads; it is not enabled globally.
- [Apple controller power getter](https://developer.apple.com/documentation/iobluetooth/iobluetoothhostcontroller/powerstate)
  and [Core Bluetooth states](https://developer.apple.com/documentation/corebluetooth/cbmanagerstate)
  are documented alternatives, not live-validated replacements in this change.
- [Diagnostic policy](../diagnostics.md), [module ownership](../modules.md),
  [historical Bluetooth evidence](../validation/bluetooth-disable-responsiveness.md).

## Validation record · 2026-10-16

Implementation/test revision: `6c59dc915c076e6ff464ff5f594275a60e75ad03`,
based on `52ae53e`. Documentation recorded afterward is not a claim that the app
was rebuilt at the documentation revision. Tests use command-scoped standalone
CLT and ad-hoc signing; no global developer-tool selection changes.

Preserved intermediate failures:

- The first parser fixture still expected a missing-controller issue after adapter
  errors gained their own conservative rejection. The expectation was corrected;
  no live payload was involved.
- Full run at `ed98dfb` passed the real app build/signature, packaging and 63 then-current
  focused observation checks, then stopped with exit 32: `Tests/build.sh` had not
  stubbed the new focused script at its mock-compiler boundary. `e7230a5` adds that
  stub and checks both new production Swift inputs appear exactly once.
- The next run was invalidated by a source edit during compilation. Its compiler
  reported “input file ... was modified during the build”; it is not accepted
  full-suite evidence. Production source was then frozen at `6c59dc9` for the final
  run. Its new owner-boundary test prevents a non-UI caller from bypassing the
  initial comparison; an injected coherent-off case retains the existing explicit
  power-on action and verifies it through the original fake helper only.

Focused observation checks, permission-context checks, diagnostics, C assertions,
policy tests and legacy checks are separate totals, never added into one count.
Fixture executables exercise cancellation, TERM resistance, inherited pipe
holders and output limits without invoking installed blueutil or system_profiler.
There was no app launch/quit/install, live Bluetooth query/control or permission
change, device mutation, system-preference reset, control-path replacement, push
or merge. Existing default tests retain their read-only runtime capability probes.

### Frozen-revision results

At **`6c59dc915c076e6ff464ff5f594275a60e75ad03`**:

```sh
MAC_UTILS_SIGNING_IDENTITY=- DEVELOPER_DIR=/Library/Developer/CommandLineTools bash test.sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools bash scripts/dev lint
DEVELOPER_DIR=/Library/Developer/CommandLineTools bash scripts/dev format-check
```

All passed. Separate results:

| Runner | Result |
| --- | --- |
| Legacy app/host/feature runner | **4,737 checks**; includes six new actual-host native observation/projection/error-ownership assertions |
| Focused Bluetooth observation | **66 checks**, including zero mutation commands in the contradictory off/empty versus on/six/two-saved-target case |
| Focused permission-context characterization | **32 checks**, unchanged installed-helper/TCC isolation |
| Diagnostic review regressions | **81 checks**, plus production no-flush/no-sync-wait safety guard |
| Gesture terminal safety | **114 C assertions**, zero failures |
| Clipboard policy | **10 Swift Testing tests in 3 suites** |
| Installer fixtures | **13 mocked scenarios** |
| Lint / format | **67 Swift files**, zero lint violations / zero formatting changes required |

The full run also passed real app compilation/ad-hoc signing, exact bundle
notices, strict signature and relocated-bundle checks, staged replacement/rollback
fixtures, compiler-input ownership and SwiftUI compatibility. The built plist's
`FixMacOSRevision` was read back as the exact frozen revision above, without
executing the app. Compiler: standalone CLT, Apple Swift 6.4
(`swiftlang-6.4.0.34.1`), Swift 5 language mode, arm64/macOS 15 deployment target.
This is isolated build/test evidence, not native Bluetooth/hardware acceptance.

Ignored local logs under this worktree's `build/`:
`bluetooth-observation-6c59dc9-{full,lint,format}.log`;
`bluetooth-observation-admission.log` retains the standalone 66-check run.
Offline developer-tool fixtures passed in `bluetooth-observation-tools.log`;
touched shell syntax and whitespace checks passed. Local link checks resolved
87 relative documentation paths. Earlier failed logs remain alongside these;
they are not substituted for the final passing revision.

Independent review is required before merge. The implementation does not prove
why the running helper returned contradictory data, that blueutil can control
those devices, or that a real user's installed app loaded this new code.

### Independent review blocked `6c59dc9`

The passing checks above missed two confirmed regressions: pre-reconnect helper
inventory remained in presentation after automatic connection, and saved/native
address spelling could fail exact helper target lookup and manual toggling.
The reviewer also saw one unexplained exit-75 subprocess fixture failure before
eight subsequent passes. Those passing reruns do not resolve the flake. Fixes,
targeted red/green evidence and independent follow-up are required before merge.
