# Bluetooth reconnect: native control qualification

## Stage 1 result · 2026-10-18

Based on main `9225999`, isolated branch `sol/bluetooth-qualified-control`.
**Reconnect is not fixed by this stage.** The production-backend fixture reproduces
the reported failure: helper power off / empty inventory, native controller on /
six disconnected devices, two saved targets, protected audio enabled. Reconciliation
blocks before any connection attempt. This is a control-path failure, not an Audio
configuration failure. Audio sources and preferences remain unchanged.

The parent reports the running app as `f0d8cf1`, PID 35520, with allowed Bluetooth
authorization. Those are supplied observations, not newly collected app-context
evidence. The current process cannot load new instrumentation without a separately
authorized replacement/relaunch. No shell query can establish the same app context.

## Documented candidate, not private preference power

Apple's documentation and the installed CLT SDK agree:

- [`IOBluetoothHostController.powerState`](https://developer.apple.com/documentation/iobluetooth/iobluetoothhostcontroller/powerstate)
  is a read-only controller getter, with 1 on and 0 off. A missing controller or
  unknown value must remain unknown. It does not use blueutil's private preference
  getter or request a new `CBCentralManager` permission prompt.
- [`IOBluetoothDevice(addressString:)`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/init(addressstring:))
  looks up an object directly by colon-form address. Object existence alone does
  not establish pairing. Avoid `pairedDevices()` as the qualification mechanism:
  it repeats the inventory interface already suspected in the helper.
- [`isPaired()`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/ispaired())
  reports pairing. Require true in the app process, matching the canonical saved
  target. A false contextual getter is a blocker, not grounds to pair a device.
- [`openConnection(_:withPageTimeout:authenticationRequired:)`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/openconnection(_:withpagetimeout:authenticationrequired:))
  is asynchronous **only with a non-nil callback target**. Its immediate success
  means command issued, not connection established. Completion arrives through
  `connectionComplete(_:status:)`. Nil-target and no-argument variants block and
  must not run on the UI thread or a worker required for quit drain.
- [`isConnected()`](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/isconnected())
  reports a baseband connection. Completion status plus fresh identity, pairing,
  controller and connection readback must verify success. This is not proof of
  an audio profile or audio output selection; Audio remains its existing owner.

Official DocC JSON for controller state, pairing and the asynchronous method was
fetched during this investigation. Local headers inspected:
`IOBluetooth.framework/Versions/A/Headers/objc/IOBluetoothDevice.h`, lines 153–174,
560–622 and 885–891; `IOBluetoothHostController.h`, lines 48–60, under the CLT SDK.

## Implemented read-only app probe

`BluetoothControlProbe` lives beside the existing observation types. Production
composition supplies its native getter adapter; injected backends get no probe
unless explicitly supplied. A blocked successful helper comparison invokes it on
the existing Bluetooth serial utility worker, at most once per 30 seconds.

It checks current static parent authorization before controller lookup and again
before each device lookup. It never constructs a central manager. It reads the
documented controller state and directly looks up saved, protected and valid native
candidate IDs. It verifies returned identity before counting true pairing and
connection getters. Invalid/colliding IDs, duplicate inventory, cancellation and
more than 64 candidate lookups fail closed. No device objects or identities persist
between probes. The worker-owned probe is not a concurrent public interface.

`bluetooth/native_control_probe` records one UUID, duration, closed stages and
counts, including saved/protected pairing counts. It always reports
`control_capability=unverified`. No names, addresses, native device objects, raw
errors or profiler JSON enter diagnostics. Existing signal/error UUID publication,
helper evidence, native provenance, admission, retries and Audio policy are intact.
The probe has no mutation methods and never grants control admission.

## Proposed control interface and lifecycle

After app-context getter qualification, implement one small adapter interface:

```swift
protocol BluetoothConnectionControl {
    // Owned serial run-loop executor; callback exactly once; no UI waits.
    func connect(_ validatedTarget: ValidatedBluetoothTarget,
                 completion: @escaping (BluetoothConnectionResult) -> Void)
    func cancelAndDrain(completion: @escaping () -> Void)
}
```

`ValidatedBluetoothTarget` must be created internally from a unique current saved
identity, allowed parent authorization, on controller and a matching device with
true current pairing. Profiler appearance alone cannot construct it. The control
adapter retains the corresponding native object and completion delegate privately.
Do not expose an arbitrary MAC-to-connect method that bypasses qualification.

Prefer the normal helper path when its fresh reads are valid. Select direct native
control only from independently qualified getter evidence. Protection additionally
needs a complete fresh inventory and direct pairing/connection evidence for its
candidate devices, including configured protected targets. Unknown protection
state blocks reconnection rather than treating it as no connected headphones.
Never relabel direct-native readback as helper evidence to bypass existing guards.

State machine: idle → qualified → submitted → verifying → completed/failed.
Cancellation changes the generation, rejects queued work, suppresses success and
all post-connect Audio intent, and drains active logical work exactly once. Late
or duplicate callbacks cannot publish, route audio or release a newer operation.
Only verified connection readback enters the existing connected progress path.
Failures retain the existing per-target 30-second backoff; later valid targets
must not starve. No automatic power toggle, pairing or disconnect fallback.

**Unresolved lifecycle gate:** the documented asynchronous method does not document
a request-cancel operation or a deadline for callback delivery. HCI page timeout
is not proof that a callback cannot be lost. A future adapter needs injected tests
for immediate rejection, synchronous/reentrant completion, delayed/duplicate/missing
completion, stale generation and stop during submission. After a logical deadline,
do not issue another OS request while an older request might still run. Cancellation
cannot claim the physical connection was undone. Keep this distinction explicit
when reviewing bounded stop/drain behavior; do not add a semaphore wait on main.

## Required next evidence

Independent review of this read-only stage first. Then obtain explicit permission
to replace/relaunch the app with **automatic reconnection suspended in memory**
(no preference changes) for an app-context read-only probe. Collect only the safe
stage/count event and compiled revision. Expected candidate evidence: documented
controller on, both saved targets matched and paired true, protected target paired
true, valid inventory coverage. The suspension must not suppress discovery/probe.

If any getter cannot qualify there, report that exact stage. Do not infer success
from `system_profiler`, standalone shell getters or a successful build. No such
app-context run, native connection, radio change, preference write, permission
change, installation or relaunch has been performed in this stage. A native
control implementation and independently reviewed fake completion/drain tests
remain required before reconnect can be called fixed.

## Isolated checks

`DEVELOPER_DIR=/Library/Developer/CommandLineTools bash Tests/bluetooth-observation-regressions.sh`
passed 168 checks, including 16 new direct-getter qualification, privacy and actual
backend-reproduction assertions. All native getters in these checks are injected;
no live Bluetooth or profiler calls occur. The unmodified initial branch passed
the existing 152-check focused suite before implementation.

Pinned format-check passed across 70 files. Normal pinned lint reported four
force-cast violations in unchanged `Sources/Features/Windows/WindowPositions.swift`
at lines 365 and 428; no changed Bluetooth file had a violation. The lint baseline
and Windows source were not changed to obtain a green result. `git diff --check`
passed. Full-suite results and independent review must be recorded separately;
these focused checks are not app-context qualification or a reconnect fix.
