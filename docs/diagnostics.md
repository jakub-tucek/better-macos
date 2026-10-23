# Local operational diagnostics

Instrumented builds, once started, admit best-effort newline-delimited JSON to
`~/Library/Logs/Fix macOS/`. No upload service or logging opt-in is involved.
The [initial integration record](#main-integration--2026-10-15) and
[later level/reader integration](#log-level-main-integration--2026-10-18) record
source/isolated checks, not current running-process identity. Building a new bundle
does not reconfigure or replace an already-running process.
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

### Levels and next-launch configuration

Levels, most to least verbose: `trace`, `debug`, `info`, `warning`, `error`.
`all` aliases `trace`. Normal builds default to `info`; building never embeds a
machine's local verbosity or changes its preferences. Each process resolves once:
valid `MAC_UTILS_LOG_LEVEL` environment override, then the app's `diagnostics.level`
preference, then `info`. Invalid values fall through to the next source. Parsing
ignores case and surrounding whitespace. There is no redaction bypass or `off` mode.

For **all logs on this Mac on the next launch**, including LaunchServices/login
launches and same-bundle helpers, write only the logging preference:

```sh
defaults write io.github.jakub-tucek.mac-utils diagnostics.level -string all
defaults read io.github.jakub-tucek.mac-utils diagnostics.level
```

To return to the normal default, delete only that key:

```sh
defaults delete io.github.jakub-tucek.mac-utils diagnostics.level
```

These commands do not relaunch an app. Already-running processes retain their
startup configuration, and an older binary cannot acquire missing instrumentation
retroactively. Relaunch still needs authorization. For a separately authorized
direct development launch, use the executable rather than assuming `open` forwards
the shell environment:

```sh
MAC_UTILS_LOG_LEVEL=all "build/Fix macOS.app/Contents/MacOS/fix-mac-os"
```

Child processes inherit the launch environment unless their launcher replaces it;
the saved preference also applies without inherited environment. This is a local
logging setting, not a build/distribution default. Do not launch a second GUI over
an existing instance to change logging.

`process/startup` always bypasses the threshold and reports `effective_log_level`,
`log_level_source` (`environment`, `preference`, `default`) and sanitized invalid-value
flags. Raw configuration text is never logged. Preference reads run on the utility
worker; while resolution is pending, admission still has the same 128-record cap.
After resolution, below-threshold records never occupy pending slots. The worker
also filters any already-admitted records. No startup/configuration I/O blocks a
safety caller. Best-effort delivery can still lose the startup record.

### Compact local timeline (Command Line Tools only)

```sh
bash scripts/dev logs
bash scripts/dev logs --all --limit 200 --category bluetooth
bash scripts/dev logs --level warning --since 2026-10-18T10:00:00Z
bash scripts/dev logs --session <UUID> --all
bash scripts/dev logs --pid <PID> --all
```

The default shows the latest verified live GUI session's recent warnings/errors
and startup/discovery/observation/manual-result state, at most 60 events. `--all`
includes debug/trace records already retained on disk; it cannot recover filtered
or dropped events. `--level` selects that severity and above; category, timestamp,
session/PID and 1–200 output-limit filters compose. Explicit PID selects its latest
retained startup, including historical/helper runs; explicit session works even
when startup has rotated away. See `bash scripts/dev logs --help`.

Automatic selection checks the startup's GUI role, executable basename and OS
process birth time, rather than taking the newest helper file or trusting PID
liveness alone. If startup was evicted, birth cannot be verified, or the app is not
running, it fails explicitly; select a retained session yourself. Birth comparison
allows less than five seconds of entry delay and otherwise fails conservatively.
The tool reads at most 24 owned, regular, single-link files of at most 512 KiB,
using no-follow descriptor-relative opens. It sorts JSON events across rotations,
skips malformed/partial lines and rejects record/filename PID-session mismatches.
Modification times never select files or order events. Timestamp ties use numeric
PID ascending, then the exact filename session UUID string ascending. This is a
deterministic cross-session display order, not evidence of which process acted
first. Within one PID/session, ties use generation `2`, `1`, `0` (oldest first),
then original file line order. Thus `--limit 1` selects the newest equal-timestamp
event in the selected session even if file modification times were reversed.
Explicit session/PID filters apply to parsed filenames before the 24-file budget.
More than 24 matching valid files fails explicitly with a request to narrow the
selection; the reader never silently truncates a selected session's generations.
Missing files are skipped; missing directories/sessions fail clearly. It does not
upload, launch the app, call Bluetooth, read archives or enumerate preferences.
`--directory PATH` supports isolated fixtures. The wrapper compiles a temporary
reader with the selected CLT and removes that invocation's binary afterward; no
Python, jq or Homebrew installation is required.

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
  At debug, command configuration adds the deadline under the same operation ID.
  `reported_failure` classifies only a bounded stderr prefix's allowlisted phrases:
  reported timeout, not-paired, access failure or connection failure; otherwise
  `unknown`. These are command-reported symptoms, not verified permission/pairing
  causes. Raw output remains excluded at every level, including `all`.
- Bluetooth debug events correlate manual queue/replacement/cancellation and cycle
  start/finish; automatic attempts, verified reconnects and retry scheduling share
  the cycle ID plus an attempt ordinal. No device identifier, name, raw progress
  reason or error text is added. Canceled cycles cannot claim successful completion.
  Their separate `backend_result` retains success/failure returned by the backend;
  cancellation does not prove an in-flight device mutation was undone. Observation
  conflicts/failures use warning severity; cancellation uses debug and retains the
  cached issue separately from the current fetch result/timeout flag.
  Trace adds small cache/backoff/coalescing events with native snapshot age, at the
  existing poll cadence, not per subprocess read. Observation start/finish IDs are
  distinct from host publication and command IDs; timeline proximity alone does
  not prove cross-layer causation. Host debug events expose closed admission phase
  and quit drain; warning vetoes include the closed busy/mouse/clipboard/recovery
  reason. Existing host and feature admission/restoration policy is unchanged.
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

## Verbosity and local reader · 2026-10-18

Implementation/test revision `76aa5e9`, based on main `78c8543`, adds the levels,
worker-side configuration, closed operational context and local timeline above.
The descriptor-relative backend, 128-event / 16-KiB admission bounds and file
retention limits remain unchanged. New work still requires independent review
before integration; historical backend review is not review of this extension.

Isolated checks at this revision:

- **160 diagnostic regression checks**, including the previous 81 backend checks,
  threshold ordering/startup exceptions, invalid configuration, gated preference
  loading, pre-resolution filtering, resolved admission filtering, real trace
  rotation, host veto correlation and child-process environment/preference sources.
- **13 reader fixture checks**: rotations and sessions, malformed/partial lines,
  unrelated files/symlinks, GUI versus helper/dead/reused PID birth evidence, combined
  timeline filters and missing/invalid input. No user log paths in those fixtures.
- **152 focused Bluetooth observation checks**, including all-level privacy,
  cache trace, manual correlation/rejection, canceled cycles and fetch severity.
- Pinned lint/format passed across **70 Swift files**; offline developer-tool and
  CI-whitespace fixtures, touched shell syntax and whitespace checks passed.

Earlier full-suite attempts were not accepted: one exceeded a 120-second command
limit; one exposed the mocked build fixture's missing stub for the new reader
entry point (corrected in `247ebcb`); an unfrozen attempt rejected a test source
modified during compilation. Their ignored logs remain local; none is a passing
full-suite result.

Frozen `76aa5e94d275526aed397d99610fd5cedbefcfe5` then passed one complete
`DEVELOPER_DIR=/Library/Developer/CommandLineTools MAC_UTILS_SIGNING_IDENTITY=- bash test.sh`
run: **4,805 legacy checks**, **160 separate diagnostics**, **13 reader fixtures**,
**152 observation**, **39 permission-context**, **114 C safety checks**,
**10 policy tests / 3 suites**, **13 mocked installer scenarios**, build fixtures
and signed/relocated-bundle packaging checks. These are separate runner counts;
focused coverage overlaps legacy coverage and must not be added into one total.
Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), standalone CLT / SDK 27.0; app/test target
arm64/macOS 15 in Swift 5 language mode. Built plist revision matches `76aa5e9`.
The artifact predates this evidence-only documentation change. Ignored local logs:
`diagnostics-76aa5e9-{full,bluetooth,lint,format,tools,ci-whitespace}.log`,
`diagnostics-level-tests.log`, `diagnostics-reader-tests.log` and
`diagnostics-live-reader.log`. Full execution and focused passes do not supply
independent review or hardware acceptance.

Read-only reader follow-up `ed0c742` reproduced an equal-timestamp rotation-order
inversion with fixed-mtime fixtures, then corrected the bounded file read order.
Its **13 reader checks** and unmodified pinned lint/format across 70 Swift files
passed. Red/green logs: `diagnostics-reader-tie-{red,green}.log`; final tooling logs:
`diagnostics-final-{lint,format}.log`. App sources are unchanged from the full-suite
revision above. The full suite/app build was not rerun for this reader-only fix;
do not describe the existing bundle as built from `ed0c742` or this evidence commit.

### Independent follow-up: mtime ordering and rendered filter coverage

Review found `ed0c742` incomplete: mtime still preceded generation order, so a
`-2` startup with mtime 2000 and a `-0` event with mtime 1000 could appear in reverse
order when their event timestamps matched. The earlier equal-mtime test did not
cover this case. A temporary copy of that previous reader and the reversed-mtime
fixture reproduced the failure; `diagnostics-reader-review-red.log` retains it.

Reader-only correction `11d44f4` parses the exact PID/UUID/generation filename
grammar and merges by event timestamp with the explicit identity/generation/line
tie-break above. It removes mtime-based candidate truncation: an explicit selection
is filtered before the file budget; an over-budget selection fails rather than
silently hiding its older rotations. Owned-file, no-follow, single-link, 512-KiB
file and 24-file input limits remain in force. No logger/app source changed.

**31 reader fixture checks** passed: existing unrelated-file/symlink,
malformed/missing-input and process-birth scenarios plus reversed/equal mtimes,
three-generation batches, same-timestamp line order, deterministic mixed-session
ties, newest-event `--limit 1`, over-budget selection and actual rendered-output
assertions for session/PID/category/level/since/all combinations. The old combined
filter invocation only checked that it did not throw; its replacement asserts
exact included/excluded rows and the output count. Pinned lint and format passed
across 70 Swift files; `git diff --check` passed. Logs:
`diagnostics-reader-review-{green,lint,format}.log`.

No full suite or app build was repeated for this reader-only change. The frozen
full-suite/app evidence remains `76aa5e9` above. No live logs, preferences, app,
permissions or devices were accessed or changed during this follow-up; all inputs
were isolated fixtures. **Independent re-review remains required before merge.**

The authorized machine-local change was only
`io.github.jakub-tucek.mac-utils` → `diagnostics.level=all`, verified by reading
that one key. No feature preference, permission, device, app installation or running
app was changed. The read-only live viewer refused automatic selection because
retained logs did not provide a verified live GUI startup; it did not guess a
session or launch anything. No claim is made that the running binary uses these
new events, that prior missing events can be recovered, or that any underlying
Bluetooth/host issue is fixed. Relaunch and hardware acceptance remain separate.

## Log-level main integration · 2026-10-18

The parent supplied final independent **CLEAN** review of `sol/log-level`, including
the mtime-independent identity/generation ordering correction and 31 reader checks.
The historical review-pending statements above belong to their named source
revisions, not this final supplied review. Integration preserves the source series
without new production rebinding or conflict resolution.

Actual main was **`deb28d3`**, not the earlier `78c8543`. The intervening user commit
tracks worktree gitlinks. Its already-modified `.worktrees/sol-log-level` gitlink
was left untouched; neither that user work nor other worktree/untracked contents
were reset, staged into evidence or deleted. All six unique source commits were
verified and cherry-picked in dependency order:

| Reviewed source | Main commit |
| --- | --- |
| `247ebcb` — typed levels, operational context, local reader | `6e73459` |
| `76aa5e9` — fetch severity and canceled backend results | `f2bf6d9` |
| `ed0c742` — equal-time generation ordering | `da23479` |
| `cce2461` — frozen source evidence and local configuration | `cfd698a` |
| `11d44f4` — identity/generation order independent of mtime | `bc6a20e` |
| `3357136` — final reader-review evidence | `d2bfe45` |

No conflicts occurred. Production, tests, scripts and compiler inputs exactly match
the reviewed final branch. Typed levels are `trace/debug/info/warning/error`;
`all` selects trace, precedence remains environment → one app-domain logging key
→ info, with the documented safe invalid-value handling. Threshold resolution
and preference reading stay on the logging worker, never a host admission or
synchronous disk dependency. Descriptor-relative IO, retention capacity/permissions,
bounded asynchronous admission, privacy redaction, Bluetooth helper/control
authority and quiet session Activity semantics remain intact.

Reader tests use only isolated files and injected process-birth checks. Automatic
selection still refuses retained records without a verified live GUI startup;
an older running build is not grounds to select an arbitrary latest helper or
relax birth/session/identity checks. No live log directory was inspected here.

The user previously authorized and set machine-local `diagnostics.level=all`.
**This integration does not write, reset or re-read that preference**, nor any
other live preference. A future newly started process can resolve it to trace
unless its environment overrides it; the current process is not reconfigured by
replacing the bundle. No app quit/launch/relaunch/install was performed, no PID
or loaded-image revision is guessed, and no prior relaunch approval was reused.
No real Bluetooth/system-profiler, device, TCC/permission or login-registration
action, push/tag or publication occurred. Underlying Bluetooth/host incidents,
native/hardware and hosted-CI acceptance remain open; all logs stay local.

### Frozen integrated validation

At **`d2bfe45b782d22fe0cc79387e859c456617ef276`**, one complete, sequential
standalone CLT `bash test.sh` run passed:

| Runner | Actual integrated result |
| --- | --- |
| Legacy isolated app/host/feature | **4,805 checks** |
| Diagnostic regressions | **160 checks**, including the prior 81 backend checks, plus the production no-flush/no-sync-wait guard |
| Read-only diagnostic reader | **31 fixture checks**, including reversed/equal mtimes, generation ties, birth/GUI selection and rendered filter output |
| Focused Bluetooth observation | **152 checks**, including existing conservative helper/control authority and all-level privacy/canceled-fetch evidence |
| Focused permission context | **39 checks** |
| Instant gesture safety | **114 C assertions** |
| Swift Testing policy | **10 tests / 3 suites** |
| Mocked installer | **13 scenarios** |
| Compiler/build and real/relocated bundle | Passed, including exact notices/provenance, strict configured-certificate signature, compiler-input ownership and staged rollback fixtures |

These totals are separate, with overlapping focused coverage; do not add them
into one total or add 81 again to the diagnostic count. This main run covers the
final reader fix, unlike the earlier branch full run at `76aa5e9`.
Log: `build/log-level-integration-clt.log`, recording HEAD, timestamped commands,
command-scoped CLT compiler/SDK paths, Swift 6.4 / SDK 27.0, arm64 and explicitly
unset `SDKROOT`. Source/built plist lint, strict signature and metadata passed:
version `0.4`, build `4`, arm64/macOS 15+, SDK 27.0 and embedded revision equal
the exact tested source above. No artifact is claimed rebuilt at the later
documentation-only evidence commit.

Unmodified pinned lint/format passed across **70 Swift files**, without rewrites
or baseline changes. Offline developer-tool and CI whitespace fixtures passed.
Logs: `build/log-level-integration-{lint,format,tools,ci}.log`. Direct comparisons
retain the reviewed source tree and prove descriptor-relative `LocalDiagnosticFiles`
and rotating retention code unchanged from prior main; Bluetooth control remains
helper-authorized and canonical, with native fallback display-only. Activity,
Clipboard policy ownership, shared display/watchdog authority, vendor C ABI/safety,
login service and existing host guard outcomes remain intact. No source/test
edit raced the frozen compilation.

All **20 shell inputs**, **280 local documentation links and 63 fragments across
37 tracked Markdown files**, compiler/fixture scope comparisons and
`git diff --check` passed. `bash scripts/dev logs --help` passed without reading
live logs (`build/log-level-integration-reader-help.log`). The existing AGENTS
diagnostics pointer already covers this work and did not need expansion.
Only the three evidence/developer-doc files are staged for the evidence commit;
the user's pre-existing `.worktrees/sol-log-level` gitlink change stays unstaged.
