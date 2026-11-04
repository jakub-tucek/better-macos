# Running-app footprint · 2026-11-04

Read-only profiling of installed revision `f355785`, macOS 26.6.2 arm64.
The process had been running for about 51 hours. Source checkout was `1776650`.
No settings changes, feature disabling, app restart or live window actions were
used. This is an observation of the current session, not a controlled idle benchmark.

## Measurements

| Process | CPU mean | CPU range | Physical footprint |
| --- | --- | --- | --- |
| App | 1.76% | 0.6–3.1% | 67.5 MiB |
| Watchdog | 0.1% | 0.1% at reported precision | about 4.5 MiB |

CPU uses 15 intervals at approximately two-second spacing, excluding `top`'s
initial sample. 100% represents one CPU core. The sustained measurement followed
the stack sample; it did not run concurrently with `sample`. Short-lived Bluetooth
helper CPU is not included in either process row.

The initial `ps` reading was 13.4% CPU and 109 MiB RSS for the app. That CPU value
was not sustained. RSS and physical footprint are different accounting measures;
the latter is used in the table. Virtual address-space reservations and shared
framework mappings are not private RAM consumption.

`sample` and `vmmap` agree on 67.5 MiB current and 258 MiB lifetime peak app
footprint. `vmmap` reports about 30.2 MiB of allocated malloc objects and 14.2 MiB
of dirty/swapped malloc fragmentation. A short stable sample neither proves nor
rules out a leak. Peak attribution needs a controlled UI open/close experiment.

Local raw evidence, ignored by Git:

- `build/footprint-top.txt`: initial observation during sampling.
- `build/footprint-baseline.txt`: sustained app/watchdog measurement.
- `build/footprint-sample.txt`: eight-second stack sample.
- `build/footprint-vmmap.txt`: memory-region and allocator summary.

## Findings and next optimization candidates

1. **Repeated UI publication and icon construction.**
   `AppDelegate` subscribes to every `DashboardModel.objectWillChange` and queues
   `refreshStatusIndicator()`, which constructs and assigns a new image each time.
   `AudioModule.poll()` calls `onChange` even for unchanged state every two seconds;
   `refreshAudio()` then assigns numerous published properties. Bluetooth also
   publishes progress/readback state. The sample contains icon construction,
   Audio/Bluetooth projection and SwiftUI layout stacks. First candidate: deduplicate
   state publication and coalesce icon updates, rendering only when the icon's
   actual inputs change. Measure before/after; sample counts are not CPU attribution.
2. **Polling and external helpers.** Audio enumerates devices every two seconds;
   Bluetooth cycles every five seconds and the sample catches `blueutil` process
   orchestration. Prefer CoreAudio property notifications with reconciled fallback
   polling. Evaluate Bluetooth backoff without losing reconnect/manual-operation
   semantics or replacing the qualified helper boundary with unqualified native
   control. Parent-process metrics omit child CPU.
3. **Memory and retained views.** Current combined footprint is about 72 MiB.
   Investigate the 258 MiB peak with repeated popup/Settings/palette open-close
   cycles and allocator snapshots before changing view retention. Retained views
   also preserve drafts and reduce reopen cost.
4. **Safety heartbeat.** The main process atomically writes a heartbeat and reads
   readiness every 0.5 seconds. These stacks appear in the sample. The watchdog
   itself is small; preserve the hang-detection/recovery contract during any change.

QuitGuard's 30 Hz timer runs only during a held key, not continuously. Battery
polls every five seconds; Clipboard capture polls every 0.5 seconds when recording.
Those rates alone do not establish their CPU costs in this session.

Suggested acceptance target for a later optimization: under 0.5% combined average
CPU with UI closed and no pending operation, stable memory across repeated UI
cycles, and unchanged recovery/input behavior. This is a proposed target, not a
measured guarantee. No deployment was performed in this audit.

## Follow-up: suppress redundant presentation work

The first optimization deduplicates Audio/Bluetooth dashboard assignments,
coalesces menu-bar notifications into one queued refresh per turn, caches the most
recent icon by symbol/accessibility description, and avoids assigning unchanged
native images/tooltips. Polling, routing, recovery and heartbeat behavior stay
unchanged. The icon cache is bounded to one image.

A production-host test with injected audio discovery runs 100 unchanged polls.
Compiled against the original `AppDelegate`, it records **1,000** dashboard
publications and fails the zero-publication assertion. With the changed host it
records **zero**. Separate tests cover device rename, repeated discovery error,
recovery, zero route writes, notification coalescing and icon state transitions.
One hundred model notifications queue **one** status refresh and read final state
after `objectWillChange`; unrelated state changes reuse the same image object.

Run `build/isolated-tests --idle-presentation-tests` after rebuilding the isolated
runner. This is a work-count regression result, not a measured live CPU reduction.
The running app still needs an authorized deployment and comparable profiling to
establish CPU and memory savings.
