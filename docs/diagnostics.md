# Local operational diagnostics

The app and its helpers write newline-delimited JSON automatically to
`~/Library/Logs/Fix macOS/`. No upload service or logging opt-in is involved.
Each process/session has `fixmacos-<pid>-<session>-0.jsonl` (current), then `-1`
and `-2` (older). Files are capped at 512 KiB; all sessions share a 24-file
budget (12 MiB). Old files, including old live-session files, can be evicted.
Only this exact owned filename grammar is pruned; unrelated files are untouched.
The directory is mode 0700, files 0600. `.rotation.lock` coordinates helpers;
a busy lock drops an event rather than blocking feature work. Disk/permission
failures also drop events and never veto actions. This is best-effort diagnostic
evidence, not an audit journal or crash/power-loss durability guarantee.

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

- Startup captures the compiled Git **base revision** embedded by `build.sh`,
  PID/session, entry uptime, signing code-directory hash/flags when available,
  and bundle metadata read **once at process entry**. `compiled_source_state`
  records clean/modified (or unknown on Git failure) for production build inputs;
  a modified build can differ from its Git base (not a complete build digest). Bundle
  version/revision and signing hashes/flags are explicitly marked *observed at
  entry*, not proof of the loaded image if a replacement happened before entry.
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

## Isolated validation · 2026-10-15

Implementation `c555a888eea76790479233e4e359dd155ad4a19c`, based on `e58dfe9`:

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
