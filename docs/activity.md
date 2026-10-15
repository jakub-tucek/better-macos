# Session activity

**Settings → General → Show activity…** opens one reusable, resizable Activity
window. It never opens automatically, adds no menu-bar indicator or sidebar
category, and sends no notifications.

## History and privacy

This is **memory-only history for the current app session**, not a persistent audit
trail. The latest 300 operations are retained, including queued and unfinished
operations. Older operations are evicted. Closing the Activity window keeps the
history; quitting the app loses it. Relaunch does not load previous diagnostic
files or feature recovery records into Activity.

**Clear activity** clears only this history. It does not erase saved window
layouts, Clipboard history, preferences, display/mouse recovery records, or
technical diagnostic files. A late completion cannot resurrect a cleared or
evicted operation. New operations after Clear can appear normally.

Entries carry closed typed descriptions, counts and outcomes. They do not carry
device names/addresses, window titles, app identities, user-provided layout names,
clipboard content, raw errors, paths, helper output or command arguments. This
restriction applies at emission, not only when rendering text.

## What entries mean

Entries are ordered by request/start time, newest first. A queued or started
operation becomes one immutable final result in the same row, without moving to
the top again. Timestamps use local wall time with seconds and an accessible full
date/time. Outcomes are text, not color alone. Details can be expanded and selected.

- **Displays:** requests and helper outcomes, confirmation requests, explicit Keep,
  and recovery. Recovery distinguishes user requests, confirmation expiry,
  uncertain helper failure, feature-disable preparation and quit preparation.
  A helper failure may occur after a change took effect; it is not evidence that
  hardware stayed unchanged. Confirmation requests are historical facts; later
  Keep/recovery results appear separately. Helper success does not verify a
  physical screen's appearance. Repeated unsuccessful automatic recovery retries
  with the same reason are omitted until success or a new display change.
- **Window layouts:** saved counts and actual restore results from the owner.
  Only successful, non-parking moves count as restored. Missing, ambiguous,
  unsupported, excluded and failed windows remain distinct. Invalidation and
  changed conditions record cancellation with the confirmed move count. This is
  not general window tracking and does not attribute macOS/other-app movements to
  Fix macOS. Layout saving reports app-preference submission, not crash durability.
- **Keep awake:** actual timed start/extend/stop/retry outcomes, assertion
  maintenance failures/recovery, app-rule protection changes and timed expiry.
  Expiry can leave an app rule active. Failed release retains cleanup ownership;
  no successful stop is claimed. Countdown ticks do not create entries.
- **Bluetooth:** queued/manual requests, per-target automatic attempts, verified
  connection results, audio-protection waiting and scheduled retry failures.
  Overall cycle success is not treated as success for every target. Repeated
  unchanged waiting and retry-failure observations are suppressed within an
  episode; later recovery is a separate successful entry. Polling itself is not
  activity. A connection does not establish that an audio route changed.

Triggers are **You**, **Automatic**, or **Recovery**. The journal does not yet cover
all features or every possible OS effect. Login, Audio, Mouse, Clipboard and other
feature-policy entries are outside this first slice.

The view retains row identities and expanded details. It follows incoming rows
only while at the top. While reading older rows, native scroll-target anchoring
keeps the reading position and a Show latest action is available. The 300-entry
cap still applies while reading; evicted history cannot be preserved indefinitely.

## Implementation and verification

`Sources/Core/ActivityJournal.swift` is Foundation-only, bounded and main-thread
owned. The host injects one journal into owners. `ActivityPresentation` in
`Sources/SharedUI/ActivityView.swift` observes it separately from Dashboard, so
journal updates do not refresh every Settings/widget consumer. Native window
composition stays in `AppDelegate`. SwiftUI local state uses `StoredState`.

No file I/O, database, actor hops, diagnostic-worker subscription, raw JSON parsing,
flush or quit veto is involved. The journal is observational: host admission,
feature restoration responsibility and asynchronous drain remain unchanged.
Technical diagnostics retain their independent best-effort delivery and retention
contract; see [diagnostics](diagnostics.md).

`Tests/ActivityTests.swift` exercises the production journal and injected feature
owners/host callbacks, including bounded pending rows, clear/eviction, immutable
results, partial/canceled window restore, awake expiry/failures, mixed Bluetooth
target outcomes, queued cancellation, privacy sentinels, display helper uncertainty
and native window reuse. Default fixtures do not operate live devices, grant
permissions, read user log files, or launch the production app.

Isolated tests and native hosting fixtures are not physical-device acceptance or
proof of live keyboard/VoiceOver delivery. Live visual scrolling, disclosure/text
selection, date formatting, accessibility, and hardware outcomes still require
separate user-authorized acceptance. No prior relaunch authorization is extended
by adding this feature.
