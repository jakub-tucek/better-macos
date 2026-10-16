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
  controls are unavailable, even from non-UI callers. Host admission remains
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
