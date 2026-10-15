# Local operational diagnostics

The app and its helpers write newline-delimited JSON automatically to
`~/Library/Logs/Fix macOS/`. No upload service or logging opt-in is involved.
Each process/session has `fixmacos-<pid>-<session>-0.jsonl` (current), then `-1`
and `-2` (older). Files are capped at 512 KiB; all sessions share a 24-file
budget (12 MiB). Old files, including old live-session files, can be evicted.
Only this exact owned filename grammar is pruned; unrelated files are untouched.
The directory is mode 0700, files 0600. `.rotation.lock` coordinates helpers;
a busy lock drops an event. The caller admits at most 128 active/pending records
under a short in-memory lock (at most 16 KiB of fields per admitted event);
encoding, metadata collection and all filesystem work run on one utility worker.
Admission drops full/oversized events before scheduling; it does not enqueue an
unbounded dispatch task or payload per attempt. Disk/permission failures drop
events and never veto actions. Production never flushes or waits for delivery,
including helper startup/exit; a short-lived helper may leave no log record.
This is best-effort diagnostic
evidence, not an audit journal or crash/power-loss durability guarantee.

An existing directory is accepted only after no-follow open, directory type and
ownership validation; permissions are set through that descriptor. Subsequent
open/stat/enumerate/rotate/unlink operations are descriptor-relative. If the path
is renamed or replaced, the writer remains on the original owned inode (or fails
closed), never follows the replacement. Restarting creates a fresh validated
writer. Regular files must be owned by this user and have exactly one hard link.

## Read locally while reproducing

Find current files (helpers have distinct PIDs and sessions):

```sh
ls -lt "$HOME/Library/Logs/Fix macOS/"/*.jsonl
```

Pick the GUI process's `-0.jsonl` using its `process/startup` record, then:

```sh
tail -F "$HOME/Library/Logs/Fix macOS/fixmacos-<pid>-<session>-0.jsonl"
jq -c 'select(.category == "bluetooth" or .category == "login")' \
  "$HOME/Library/Logs/Fix macOS/"/*.jsonl
jq -c 'select(.category == "clipboard_storage" or .category == "settings" or .category == "popover")' \
  "$HOME/Library/Logs/Fix macOS/"/*.jsonl
```

`jq` is optional; `tail` works without installing anything. Record the time of
the attempted action and inspect correlated `operation` IDs in that `session`.
Timestamps use UTC wall time; durations use monotonic time. Files are independent,
so glob order is not chronological. Do not paste clipboard content or command
output into bug reports. Inspect logs locally before sharing even a small excerpt.
App launch/relaunch, permissions, device operations and installation still require
the user's authorization; adding logs does not authorize those checks.

## What the evidence means

- Startup admits the compiled Git **base revision** embedded by `build.sh`,
  PID/session, entry timestamp and uptime without waiting for the writer.
  `compiled_source_state`
  records clean/modified (or unknown on Git failure) for production build inputs;
  a modified build can differ from its Git base (not a complete build digest). Bundle
  version/revision and signing hashes/flags are collected **asynchronously on the
  worker**, explicitly named `observed_on_worker`, and marked
  `metadata_capture=asynchronous_not_loaded_image`. They are not a snapshot of the
  loaded image or entry-time disk contents: replacement may precede collection.
  No later disk read is presented as a loaded Git SHA. Paths/storage identity
  are SHA-256 hashes plus a build/applications/other location class; no home path
  or signing certificate name is recorded. The signing API may fail; its status
  is retained without turning logging into an admission check.
- Preferences record the app domain and presence of `clipboard.persistence` and
  `clipboard.days`, not a defaults dump. Absence is distinguishable from a saved
  value. Clipboard configuration requests distinguish startup from explicit user
  changes. Archive load/save/clear report reason, success/failure, coarse failure
  class, numeric error code, duration and entry counts when known.
  Failure/retry/restoration policy is unchanged. No
  clipboard text, image bytes, entry IDs, private markers, source app identities,
  exclusions or search strings enter the diagnostic event API.
- Bluetooth command records contain an allowlisted operation, exit code (including
  75), monotonic duration, timeout flag and output byte counts. Arguments, device
  names/MACs, stdout, stderr and raw error descriptions are never logged. A launch
  failure is separate from a command exit failure; the log does not guess that
  exit 75 means a specific authorization/device problem.
- Login requests include before/after registration/approval state, numeric failure
  code and a coarse error class, not localized error payloads. Status observations
  are deduplicated by the host. Success can still require system approval.
- Settings category changes report the existing new-ScrollView-identity reset
  request and content appearance. **Actual scroll offset is not observed** and
  reset success is not claimed. Popover events report anchor size, visible-frame
  size and resulting margins on the next main-queue turn; this is not a screenshot
  or proof that placement remains unchanged after later animation/layout.

The isolated diagnostics tests use injected sinks, clocks, filesystem failures,
temporary fixture executables, fake clipboard/archive backends and fake login
registration. They do not read the user's clipboard, enumerate preferences,
register login items, launch the app or operate real Bluetooth devices. Native
reproduction/acceptance is a separate, user-authorized step.

## Historical isolated validation · 2026-10-15

Implementation `c555a888eea76790479233e4e359dd155ad4a19c`, based on `e58dfe9`:

**Independent review subsequently BLOCKED this implementation on all three
findings below.** These passing checks had coverage gaps and did not establish
repeat-launch logging, nonblocking caller delivery or parent-replacement safety.

- `MAC_UTILS_SIGNING_IDENTITY=- DEVELOPER_DIR=/Library/Developer/CommandLineTools bash test.sh`
  passed: **4,395 legacy checks**, **10 policy tests / 3 suites**, **13 mocked
  installer scenarios**, compiler/build fixtures, real and relocated bundle
  notices/signatures/metadata. Built plist revision matches that implementation.
- Standalone CLT 27, Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), arm64/macOS 15 target.
  Pinned lint and format checks passed across 50 Swift files; offline developer-tool
  regressions, shell syntax, standalone logger type-check and whitespace checks passed.
- Diagnostics checks exercise injected clocks, concurrent writers, bounded
  rotation/global retention, unrelated-file/directory preservation, permissions,
  busy-lock dropping, symlink rejection and failed I/O. An isolated executable
  produces exit 75 with sensitive fixture strings on both output streams; decoded
  JSON logs retain exit/action/correlation but omit those strings. Injected login
  failure retains approval state/code; typed archive events preserve startup
  failure/retry and explicit Clear versus startup-default cleanup reasons.

Ignored local evidence: `diagnostics-c555a88-clt.log`,
`diagnostics-c555a88-{lint,format}.log`, `diagnostics-tooling.log` in this worktree.
The artifact predates this documentation commit. No app launch/quit/install,
live clipboard/preferences dump, login registration, device action or permission
mutation was performed. **Independent review remains required before merge**;
these checks do not establish native/hardware acceptance or resolve the underlying
Bluetooth, login, Settings or retention reports.

## Independent review blockers and reproductions

All three findings reproduced before their corrections, using only temporary
directories or injected gates. Ignored local red/green evidence is retained as
`diagnostics-review-{1,2,3}-{red,green}.log` in this worktree.

1. At `3f54802`, a second real session in an existing directory failed with Cocoa
   516 because non-recursive `createDirectory` rejected the existing name before
   validation. `721d573` accepts the existing directory only after validation.
   Real-filesystem coverage now includes distinct sessions, simultaneous creation
   and post-barrier writes; the creation scenario repeats ten times.
2. At `721d573`, a sink held at a semaphore gate prevented `emit` from returning
   and prevented the caller's subsequent safety action. `ec45762` replaces the
   synchronous writer with bounded pre-scheduling admission and one serial drain.
   `f0a03ee` additionally defers backend/home-path construction and bounds the
   lifetime of per-record Foundation temporaries. A four-slot gate test submits
   1,001 events: four remain admitted and 997 are dropped while the caller and
   subsequent safety action complete. `a993b42` additionally exercises the real
   `HostTransactions.requestQuit` preparation against injected no-op backends
   while that writer remains gated, without quitting any app or touching hardware.
   Oversized payloads are not retained, accepted
   ordering is preserved, and gated startup metadata also cannot block the caller.
   Only tests may request a bounded flush; source checks reject production calls.
3. At `ec45762`, replacing a prepared directory with a symlink redirected appends
   and rotation to its target. `f1eab2f` retains a validated directory descriptor
   and uses `openat`, `fstatat`, `unlinkat`, `renameat` and descriptor-relative
   enumeration/locking. Real tests replace the path with both a symlink and an
   ordinary directory; target contents and names stay unchanged, while rotation
   and owned-session cleanup actually occur inside the original retained inode.
   Nonowned files survive and hardlinked regular files are rejected before
   content/permission mutation. Concurrent file-open retries are bounded and stay
   anchored to the same descriptor.

The focused regression runner is `bash Tests/diagnostics-regressions.sh` and is
part of `test.sh`. A green regression is not independent re-review or native
acceptance. **Independent re-review remains required before any merge.**

## Corrected-series isolated validation · 2026-10-15

Frozen implementation/test revision
`a993b423c52b03fa061ed0b8f46351e4de6550c8` passed:

- `MAC_UTILS_SIGNING_IDENTITY=- DEVELOPER_DIR=/Library/Developer/CommandLineTools bash test.sh`:
  **61 diagnostic review regression checks** plus the safety-entry source guard,
  **4,401 legacy checks**, **10 policy tests / 3 suites**, **13 mocked installer
  scenarios**, compiler/build fixtures and real/relocated bundle checks. The built
  plist revision matches this exact implementation/test revision.
- Standalone CLT 27 / Apple Swift 6.4, arm64/macOS 15 target. Pinned lint and
  format checks passed across **51 Swift files**; offline developer-tool
  regressions, touched shell syntax and whitespace checks also passed.
- The preceding production revision `f0a03ee` separately passed the full CLT run
  with 60 diagnostic regressions (before the additional real-host assertion),
  4,401 legacy checks, 10 policy tests and 13 installer scenarios.

Ignored exact-revision logs are `diagnostics-a993b42-clt.log`,
`diagnostics-a993b42-{lint,format,tooling}.log`; focused final evidence is
`diagnostics-review-final-targeted.log`. Earlier red evidence and intermediate
green/debug logs remain local and are not counted as final acceptance. The built
artifact predates this documentation commit. No user app launch/quit/install,
live clipboard/preferences dump, login registration, device action or permission
mutation occurred. These results address the reproduced logging blockers in
isolated checks, not the original feature reports or native/hardware acceptance.
**Independent re-review is still mandatory; nothing has been merged to main.**
