# Local operational diagnostics

Instrumented builds, once started, admit best-effort newline-delimited JSON to
`~/Library/Logs/Fix macOS/`. No upload service or logging opt-in is involved.
The [main integration record](#main-integration--2026-10-15) verifies source and
isolated fixtures, not logging from the already-running app. That app has **not
been relaunched** for this integration; no live user log directory was read.
Each process/session has `fixmacos-<pid>-<session>-0.jsonl` (current), then `-1`
and `-2` (older). Logger-created files are capped at 512 KiB; sessions in one
validated directory share a 24-file budget (12 MiB). Old files, including old
live-session files, can be evicted.
Only this exact owned filename grammar is pruned; unrelated files are untouched.
The budget counts owned, regular, single-link files validated by the backend;
symlinks, directories and hardlinked files are not adopted as managed records.
Capacity is reserved **before** a new current file is created, including during
rotation. Failed eviction candidates are skipped so other eligible files can
free capacity. If no capacity can be freed, delivery is dropped without creating
another file or overflowing the current file. An existing in-budget file can
still append if no new generation is needed and the size limit permits it.
Counting, eviction and creation share the same nonblocking directory lock.

An externally/pre-existing over-budget or oversized directory cannot always be
repaired: immutable/undeletable files are never force-cleared or overwritten.
Pruning is best effort; if the file budget cannot be restored, even existing-file
appends are dropped. This prevents additional managed-file growth but does not
promise deletion of undeletable files or retroactive size repair.
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

The commands below are instructions for a later authorized reproduction, not
checks performed during integration. Relaunch/installation/device or registration
actions require separate approval; do not infer a running process loaded the new
build merely because its on-disk bundle was replaced.

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
- Host `bluetooth/manual_action_finished` records use only `power_on`, `connect`
  or `disconnect`, a result and `error_cleared`. Failure uses its published error's
  UUID as the operation token; a matching verified recovery reuses that token.
  A newer identical-text or unrelated error still survives. This token does not
  identify a device or command invocation; command start/finish IDs are separate.
- Login requests include before/after registration/approval state, numeric failure
  code and a coarse error class, not localized error payloads. Status observations
  come from the injected typed `LoginServicing` status and are deduplicated by the
  host, including `requires_approval`, `not_found` and `unknown`. Registration remains
  behind host admission; read-only activation/Settings refresh never registers.
  Login's inline errors remain independent of Bluetooth's global publication.
  Success can still require system approval and does not prove next-login launch.
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

Subsequent independent follow-up confirmed the original three blockers resolved,
but reproduced a separate failed-eviction retention bug; see below. These older
passing checks did not cover immutable eviction failures.

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

## Follow-up: failed-eviction retention admission

At `35c33a2`, the real-filesystem reproduction with the oldest managed file marked
user-immutable and thirty new sessions produced **31 JSONL files and seven write
failures**. Appending preceded pruning, and the first failed unlink prevented
later eligible evictions. The all-blocked, rotation-at-capacity and distinct-sink
concurrent cases also failed. Red evidence: `diagnostics-retention-red.log`.

`82aea5b` reserves capacity before creation/rotation, continues after an eligible
candidate cannot be unlinked, and drops delivery if capacity cannot be freed.
All work remains descriptor-relative under the existing directory lock; the
bounded asynchronous caller path is unchanged. No production code clears
immutable flags or falls back to pathname-based cleanup.

The focused real-filesystem regressions now pass **81 checks** (including the
earlier diagnostics cases) plus the safety-entry source guard:

- The original oldest-immutable case stays at **24 files / zero write failures**,
  preserves immutable and unrelated files, and actually delivers the newest
  session rather than dropping every full-budget event.
- With every candidate immutable, repeated new-session writes create no files;
  a pre-existing over-budget directory does not grow. Existing-file appends work
  within budget and size, but blocked rotation and over-budget appends drop
  without changing current contents.
- Rotation at capacity skips a blocked candidate, evicts a later eligible one,
  and keeps file counts and sizes bounded. Distinct real sinks use a gated native
  `flock` to prove contention drops before creation; concurrent rotation probes
  check counts inside actual locked appends, not just after cleanup.

Only fixture-created files under unique temporary roots receive `UF_IMMUTABLE`;
fixture teardown restores those flags before removing its own temporary root,
including on assertion failures. No live log paths or user files are used.
Focused green evidence: `diagnostics-retention-green.log`.

Frozen implementation/test revision
`82aea5b4e25d849ee257f35f5f4bddadc7bdaaec` passed one complete
`MAC_UTILS_SIGNING_IDENTITY=- DEVELOPER_DIR=/Library/Developer/CommandLineTools bash test.sh`
run: **81 diagnostic regressions** plus the safety-entry source guard,
**4,401 legacy checks**, **10 policy tests / 3 suites**, **13 mocked installer
scenarios**, compiler/build fixtures and real/relocated bundle checks. The built
plist revision matches. Pinned lint and format passed across **52 Swift files**;
touched shell syntax and whitespace checks passed. Full evidence is
`diagnostics-82aea5b-clt.log` and `diagnostics-82aea5b-{lint,format}.log` (ignored,
local to this worktree). This documentation commit does not claim a rebuilt
artifact at its own revision. No live log directory, app launch/quit/install,
system preferences, permissions or devices were mutated; immutable flags were
used and restored only on fixture-owned temporary files.
**The same independent reviewer must re-review before any merge.**

## Main integration · 2026-10-15

The final source series through `f85ebf7` was supplied independently reviewed
**CLEAN**. It was integrated on clean main `02e4ce7`, preserving the already
reviewed Bluetooth UUID-owned error recovery and typed inline login status/error UI:

| Reviewed source | Main commit |
| --- | --- |
| `c555a88` | `b5aa824` |
| `3f54802` | `9e1d323` |
| `721d573` | `941309f` |
| `ec45762` | `03749ea` |
| `f1eab2f` | `61996ec` |
| `f0a03ee` | `ea319e8` |
| `a993b42` | `22b18b8` |
| `35c33a2` | `b1c465d` |
| `82aea5b` | `db339de` |
| `f85ebf7` | `d0941c4` |

Actual history orders the descriptor fix `f1eab2f` before deferred construction
`f0a03ee`; that dependency order was retained. Initial conflicts were restricted
to `Sources/App/AppDelegate.swift`, `build.sh` and `test.sh`: current login guards,
inline errors/read-only refresh and both login/Bluetooth test inputs were retained.
No old direct-SMAppService host action or enabled-only checkbox was restored.

New binding code and tests were isolated in **`fc30bf638dd39f1d5f6aada849d9fced37cc1739`**:
`LoginDiagnostics` now wraps `LoginServicing`, with a closed typed status allowlist;
host status refresh reads once and emits only on change. Bluetooth completion logs
retain exact operation/publication ownership and emit only safe action/result fields.
The reviewed bounded async sink, descriptor-relative IO and precreation retention
implementation were not rewritten. No Clipboard archive deletion/retention policy, automatic
radio action, login registration policy or Settings layout behavior was changed.

### Focused independent rebinding review

The local review UI could not connect after creating session
`ce1cc713-24ad-46ec-aed2-92c56f548742`; it supplied no review verdict. A separate
**read-only Codex CLI review of commit `fc30bf6`** then reported:
“No actionable regressions were identified.” It specifically confirmed retained
Bluetooth ownership/admission, typed login injection and exclusion of sensitive
payloads. It ran no tests or live OS actions. The raw review log, including sandbox
read warnings, is `build/diagnostics-rebinding-independent-review.log`; the verdict
is not inferred from the earlier source-series CLEAN review.

### Combined frozen-revision checks

At **`fc30bf638dd39f1d5f6aada849d9fced37cc1739`**, one complete standalone CLT 27
run passed **81 separate diagnostic review regressions**, the production safety
no-flush/no-sync-wait source guard, **4,498 legacy checks**, **10 Swift Testing policy
tests in three suites**, **13 mocked installer scenarios**, compiler/build fixtures
and real/relocated-bundle checks. These counts are separate: 81 is not added to
the legacy runner's count or substituted for the source worktree's historical 4,401.

The legacy total retains all prior Bluetooth/login checks plus new actual-host
diagnostic assertions: exit-75/success command and host UUID correlation, preservation
of newer identical-text errors, requires-approval/unknown/error registration through
injected services, status deduplication, closed admission and payload redaction.
Only tests use a bounded flush to inspect injected sinks; no real login API or
Bluetooth command was used.

Log: `build/diagnostics-integration-clt.log`, recording HEAD, command-scoped
`DEVELOPER_DIR=/Library/Developer/CommandLineTools`, actual Swift 6.4 / SDK 27.0
compiler/SDK paths and versions, arm64 and bundle metadata, with `SDKROOT` unset.
Strict configured-certificate signature, exact notices, source/built plist lint,
relocation/dependency checks and metadata passed: version `0.4`, build `4`,
arm64/macOS 15+, SDK 27.0, embedded tested revision. The compiled revision literal
was independently found in the binary without executing it. The clean/modified
production-input stamp generation and its fixture checks were preserved; asynchronous
disk/signature observations remain explicitly distinct from compiled identity.

Unmodified pinned lint/format passed under CLT across **55 files**; offline tooling
and CI whitespace fixtures passed. Logs: `build/diagnostics-integration-{lint,format,tools,ci}.log`.
No live log was read and the app was not relaunched, installed or quit. No real
preferences, clipboard/device/permission changes, registration/settings actions,
version bump, push/tag or publication occurred. Immutable flags were used/restored
only on fixture-owned temporary files. The evidence-only commit does not describe
an artifact built at its own revision; native/hardware, loaded-image reproduction,
next-login and hosted-CI acceptance remain open.

All **14 shell inputs**, **239 local links and 41 fragments across 31 tracked
Markdown documents**, compiler-input/privacy/scope assertions and `git diff --check`
passed. Direct comparisons confirm the final reviewed diagnostics backend,
retention regressions and Clipboard instrumentation are unchanged by rebinding.
