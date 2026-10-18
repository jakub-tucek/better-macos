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
to gracefully quit the current app and launch the reviewed same-bundle GUI in
**read-only probe mode**. This mode never constructs the normal app host and never
starts automations; it does not change any feature preference. Collect only the safe
stage/count event and compiled revision. Expected candidate evidence: documented
controller on, both saved targets matched and paired true, protected target paired
true. Full current inventory/protection coverage remains a separate control gate;
this registered-target-only probe deliberately does not run a profiler/helper.

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

## Review blocker correction: explicit read-only GUI launch

`dc2ef05` was blocked for lacking a launch path that could run the probe without
also starting normal app automations. Its normal-reconcile instrumentation alone
was not safe to use as the requested manual qualification entry point.

`ApplicationLaunchMode` now selects `--bluetooth-readonly-probe` before any helper
or mutating CLI dispatch. Its lazy delegate factory constructs only
`BluetoothReadOnlyProbeDelegate`, never `AppDelegate`. Consequently normal host
property initializers, module factories, watchdog, mouse/display recovery, input
activation, source updater, login refresh/registration and Audio never run.
No `AppDelegate` lifecycle callback or quit cleanup participates. Probe quit is
immediate, since it owns no mutations or feature restoration work.

The same app executable runs `NSApplication` with a probe-only completion window.
Native getters run on a utility worker. The window remains open after completion,
showing the run UUID, diagnostic session, PID, closed stage and public counts.
Begin, native getter result and completion use the same run UUID at info severity.
No production flush or auto-exit races diagnostic delivery. Logging remains
best-effort; a visible completed result does not prove its log was written.
Startup explicitly identifies this mode as `process_role=gui`, despite its flag.

Only `bluetooth.autoAddresses` and `bluetooth.protectedAudioAddresses` are read
through `CFPreferencesCopyAppValue` in the real app domain. Missing keys mean no
saved choice; malformed values/identities or duplicate canonical choices report
unknown counts and never construct getter capabilities. No defaults registration,
preference write, Bluetooth permission request, central manager, scan, paired-device
enumeration, helper command, power action or device connection is available to
the probe-only composition. An unexpected/unbundled executable reports
`not_app_bundle` before preference or native reads. The bundle check establishes
packaging only, **not proof of TCC identity or successful device control**.

### Later authorized invocation, not executed

After independent review, obtain one explicit approval covering graceful quit of
the current GUI and launch of the reviewed bundle in this read-only mode. Do not
launch a second instance, force-quit the current app, use `open -n`, reset TCC or
change feature choices. Normal quit may restore already-owned feature state;
that existing cleanup is part of the approval, not performed by the probe.

After the existing process has exited gracefully:

```sh
open "/Users/jakubtucek/Projects/others/fix-mac-os-bt-qualified/build/Fix macOS.app" --args --bluetooth-readonly-probe
```

Keep the result window open. Use its exact **Session** value to collect retained
events, rather than guessing the newest helper/session:

```sh
bash scripts/dev logs --session <SESSION-FROM-PROBE-WINDOW> --all --category bluetooth
```

Match `readonly_probe_begin`, `native_control_probe` and `readonly_probe_result`
by the window's **Run** token. Inspect startup in the same explicit session to
record compiled base revision/source state and GUI role. Do not use
`--bluetooth-app-status` or `--test-connect-in-gui`; the former reads an old cached
snapshot, and the latter can mutate devices/Audio. No command above was executed
during implementation. A real same-app-context getter result remains pending.

### Initial stage-1 full run, now completed

The previously pending full CLT/ad-hoc `test.sh` run passed: **4,805 legacy**,
**168 focused observation**, **39 permission-context**, **160 diagnostics**,
**31 reader**, **114 C assertions**, **10 policy tests / 3 suites**, **13 mocked
installer scenarios**, and app/build/real and relocated bundle fixtures. Counts
are separate and overlap; do not sum them. It began at base `9225999` with modified
stage-1 source subsequently committed as `dc2ef05`; no compiled source was edited
during the run. It is not a claim that the artifact embeds `dc2ef05` or includes
the later explicit probe launch. Log: `bt-qualified-full.log` in the approved
OpenCode temporary directory.

The initial lint/format errors above were path-sensitive tooling artifacts in the
temporary worktree (`/private/var` versus `/var` alias). After moving the same
isolated worktree to `/Users/jakubtucek/Projects/others/fix-mac-os-bt-qualified`,
normal pinned lint and format checks pass without Windows, baseline or configuration
edits. The old failures remain recorded rather than being recast as source fixes.
Final explicit-launch full-suite evidence and independent re-review remain required.

Before freezing the explicit-launch implementation, the focused runner passed
**190 checks**, plus its source capability/entry-order guard. New tests exercise
the typed delegate factory, zero normal-host construction, queued worker execution,
exact read-only preference keys/getter calls, malformed target/protection settings,
unbundled refusal, repeated launch callbacks, idle quit, pre-work cancellation,
info-level run correlation and redaction. UI presentation and native getters are
injected; these tests do not launch the production app or qualify its TCC context.
Normal pinned lint and format passed across **71 Swift files**, and whitespace
checks passed. Logs: `bt-readonly-focused-final.log`, `bt-readonly-lint-final.log`,
`bt-readonly-format-final.log`, in the approved OpenCode temporary directory.
