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

The view retains native row identities and expanded details. Immediately before
each update, the native viewport captures its top visible row ID and the offset
within that row. After synchronous native measurement/layout it restores both;
it follows incoming rows only if it was already at the top. Show latest explicitly
resets to the top. There is no delayed scroll correction or lazy height estimate.
If a row shrinks past the old within-row offset, the offset clamps to its remaining
bottom. If the anchor is evicted, the nearest surviving older row is preferred,
then the nearest surviving newer row, aligned to its top. Native viewport bounds
can clamp that position near the document end. If no old rows survive, it resets
to the top. The 300-entry cap still applies while reading.

## Implementation and verification

`Sources/Core/ActivityJournal.swift` is Foundation-only, bounded and main-thread
owned. The host injects one journal into owners. `ActivityPresentation` in
`Sources/SharedUI/ActivityView.swift` observes it separately from Dashboard, so
journal updates do not refresh every Settings/widget consumer. Native window
composition stays in `AppDelegate`. The native viewport owns disclosure state and
selectable text views; it does not rebuild existing rows on publication. Existing
SwiftUI `StoredState` semantics elsewhere are unchanged.

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

### Frozen-revision isolated evidence · 2026-10-15

**Historical passing evidence with a subsequent independent review concern.**
The offset-only scroll assertion below did not establish stable row identity
across batched insertions. See the reproduced failure and correction below;
these older counts are not acceptance of the corrected implementation.

Implementation **`0a7be84b48a2a3078069ef5190eb38ce4484a4f2`**, based on
`778f078`, passed one complete
`DEVELOPER_DIR=/Library/Developer/CommandLineTools bash test.sh` run:

- **4,571 legacy isolated checks**, including native hidden-window reuse and
  scrolled-history preservation, owner outcomes and privacy, and gated Clear
  during suppressed Bluetooth/display recovery retries.
- **81 separate diagnostics regressions**, plus the production safety no-flush/
  no-synchronous-wait source guard. Existing diagnostics delivery/retention code
  was not rewritten.
- **10 Swift Testing policy tests in 3 suites**, **13 mocked installer scenarios**,
  compiler/build fixtures, complete real/relocated bundle notices, metadata and
  strict signature checks. These counts are separate, not added to the legacy total.

Log: `activity-0a7be84-test.log` (ignored, local to this worktree). The built
`FixMacOSRevision` is exactly the tested implementation above; version `0.4`,
build `4`, arm64/macOS 15+ remain unchanged. A subsequent read-only
`codesign --verify --deep --strict` also passed. Host: macOS 26.6.2 (`25G83`),
standalone CLT 27, Apple Swift 6.4, SDK 27.0, Swift 5 language mode.

Pinned lint/format passed across **58 Swift files**, and standalone CLT type-checking
of the production journal, `StoredState`, and Activity view passed. Exact-revision
logs: `activity-0a7be84-{lint,format,typecheck}.log`. Earlier unchanged-tooling/state
checks passed in `activity-f3f5537-{tools,ci}.log` and `activity-7c61502-state.log`.
The complete earlier `f3f5537` run passed 4,564 legacy checks before the additional
grouped-retry Clear regressions; it is not substituted for final evidence.

Historical development failures remain in local logs: the first run exposed a
fixture that set confirmation only in the view model rather than its injected
preferences; the second exposed process-wide Bluetooth registered-defaults leakage
between isolated suites. A Foundation-only two-suite probe reproduced the latter;
the fixture now restores its registration domain. The intermediate `7c61502` run
stopped because a source file changed during compilation and is not claimed green.
The final frozen run completed after those corrections and the observer-lifetime,
expiry-crossing and Clear-generation follow-ups.

This evidence-only documentation does not claim an artifact rebuilt at its own
revision. No production app launch/quit/relaunch/install, live log read, permission
mutation, registration or device action was performed. **Independent review is
still required before integration.** Live keyboard/VoiceOver, visual interaction
and physical hardware acceptance remain open as described above.

### Independent review: batched insertion displaced the reader

Independent review reported **CONCERNS**, not CLEAN. Its read-only native fixture
showed that the old SwiftUI lazy scroll-target implementation compensated two
insertions by 166 points but then left the offset unchanged when seven new rows
grew the document by 581 points. Remaining below the top did not mean the same
row was still visible. The old `offset > 100` test had a coverage gap.

The reproduction was copied into this implementation worktree without editing
the reviewer's worktree. `activity-scroll-red.log` reproduces exactly
`insertedHeight=581.0 offsetCompensation=0.0` after the two-row case passed.
The correction replaces the lazy scroll heuristic with bounded native rows and
explicit pre-mutation row-ID/relative-offset capture and synchronous layout.
`Tests/ActivityScrollTests.swift` now asserts actual row identity and relative
offset after 2/7-row batches, successive publications, disclosure/width/wrapping
changes, terminal detail updates, surviving/evicted anchors at the cap, explicit
Show latest, top-follow, and Clear. Native row/disclosure identity is also checked.
There are no production dispatch delays, timers or eventual-correction guesses.

This correction still requires independent follow-up review before integration;
the earlier review concern is not superseded merely by implementer test results.

### Corrected scrolling: frozen implementation evidence · 2026-10-15

Correction **`182767b1e41044c02800fe36c00fa9546ee43f00`**, based on `c4adc00`,
passed one complete standalone-CLT run of
`DEVELOPER_DIR=/Library/Developer/CommandLineTools bash test.sh`:

- **4,596 legacy isolated checks**, including **27 native scrolling assertions**.
  Those 27 are part of the legacy total, not an additional suite to add to it.
- **81 separate diagnostic regressions** and the unchanged production safety
  source guard, **10 policy tests in 3 suites**, **13 mocked installer scenarios**,
  compiler/build fixtures and real/relocated bundle checks.
- Built `FixMacOSRevision` exactly matches the correction above. Subsequent
  read-only strict signature verification passed. Version/build and deployment
  target are unchanged; the environment remains CLT 27 / Swift 6.4 / SDK 27.0.

Log: `activity-182767b-test.log` (ignored, local to the implementation worktree).
Pinned lint and format passed across **59 Swift files**; the production journal,
`StoredState` and native Activity view type-checked with warnings-as-errors in
Swift 5 language mode for arm64/macOS 15. Logs:
`activity-182767b-{lint,format,typecheck}.log`. Shell syntax, whitespace and CI
whitespace fixtures passed (`activity-182767b-ci.log`).

The same 27 native assertions also pass through the focused, reproducible command:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools bash Tests/activity-scroll-regressions.sh
```

Its log is `activity-182767b-scroll.log`. This compiles the production viewport and
the same `Tests/ActivityScrollTests.swift` used by the full suite, then creates a
hidden fixture window. It checks actual visible row IDs and relative offsets,
including an expanded detail that demonstrably changes height on width changes,
and explicitly defined clamping when a visible row collapses or is evicted. It
does not rely on the old offset-only test or a delayed production scroll reset.

No reviewer worktree was edited. No main merge, production app launch/quit/install,
live preferences/device/permission actions, push or tag occurred. This later
documentation commit is evidence only, not a claim of a rebuilt artifact at its
own revision. **Independent follow-up review remains mandatory; the correction is
not yet independently CLEAN.** Native visual/keyboard/VoiceOver and hardware
acceptance gaps remain open.
