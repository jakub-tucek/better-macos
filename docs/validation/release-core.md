# Release core validation

## P1 — display recovery ownership

The host previously used dashboard counts to decide whether quit or module
shutdown needed recovery. A successful helper could commit a disable journal
before the 1.5-second snapshot gate updated those counts. Dangerous mode has no
confirmation timer, so normal quit could abandon that ownership.

Quit, display-module shutdown, and discovery lifetime now share a durable-journal
ownership check (plus outstanding rollback ownership), independent of UI counts
and cached controller records. The journal reader refreshes cross-process
preferences and fails closed for malformed display records. HostTransactions and
the centralized DisplayRefreshGate retain their existing ordering.

Regression: `bash test.sh` failed before the predicate fix at
`quit: immediate quit must wait for durable display ownership, including manual Keep`.
After the fix, the full script passed, including build, isolated tests, and
installer fixtures. Host tests exercise successful fake helpers followed by
immediate quit/last-owner module disable before any snapshot, blocked restoration,
recovery failure/retry, post-commit helper failure, manual Keep followed by quit,
and stale UI indicators after journal clearance. All journals use unique test
preferences suites; display commands, discovery refreshes, and Mouse recovery use
fakes. No real display controller is constructed by these regressions.

This is automated fake-backend validation, not live monitor/watchdog acceptance.
No app launch/quit, live display mutation, release tag, or push was performed.

## P2 — Keep Awake setup display-policy removal

Setup saved Display Awake = false, but reconciliation only handled the true
policy. Existing display assertions therefore survived while timed/app system
ownership continued. Reconciliation now removes the display assertion separately,
before system renewal, retaining its ID if release fails. The existing failed
setup outcome and unchanged-policy retry path remain authoritative.

Regression: `bash test.sh` failed before the fix at
`timed: display policy Off releases only the display assertion, retaining system ownership`.
After the fix, `bash test.sh` passed: **4,099 isolated checks**, build, and all
installer fixtures. Tests cover timed, app-only, and timed-with-paused-app-rule
ownership; policy persistence; unchanged deadlines and pauses; failed releases;
retained IDs; repeated same-policy retries; failed versus applied configuration
outcomes; and removal despite an unrelated system-renewal failure. All added
assertion tests use FakePowerAssertions, a fixed/injected clock, isolated
preferences, and disabled automatic observers/timers. No real IOKit assertion or
sleep/wake action was requested.

`git diff --check` passed. The full existing test script was run unmodified;
installer launch/quit operations are fixtures, not operations on the installed
app. Live preferences/journals, clipboard, routes, pointer, display/window geometry,
and power assertions were not deliberately modified for acceptance testing.
Parent-session independent review and any authorized live acceptance remain
outside this worktree's scope.

## Independent-review follow-up — watchdog admission

The injected readiness seam incorrectly used recovery readiness alone for new
display disables. Recovery intentionally ignores watchdog availability; new
disables must not. The host now additionally requires watchdog readiness when
requesting Off, while On and Restore retain watchdog-independent recovery.

New actual-host negative tests failed before the fix at
`new display disable cannot dispatch with unavailable watchdog supervision`.
They cover initially unavailable and subsequently lost supervision. Positive
actual-host cases disable with supervision, lose the watchdog, and still recover
before quit/module unload. All helper commands and snapshots are fake.
After the fix, full `bash test.sh` passed: **4,118 isolated checks**, build and
installer fixtures. Durable recovery ownership and the centralized gate remain
unchanged. No live watchdog or display action was performed.

## Independent-review follow-up — unreadable journal preservation

The pending predicate failed closed, but controller initialization previously
treated decoding failure as an empty record list and saved that list. The restore
helper could then report success after destroying the only recovery data.

Production initialization now uses a shared read-only throwing loader before
graphics discovery, framework loading, legacy migration, or journal writes.
Malformed JSON, invalid record shape, and non-Data preferences throw a visible
recovery-journal error. Current and legacy bytes/metadata are preserved exactly;
valid records and legacy migration still work. Snapshot, status, preview, mutation,
restore, and hardware-test CLI branches propagate initialization errors through
their existing nonzero-exit handling. GUI discovery catches the error without
installing a controller. The watchdog uses the same fail-closed ownership check;
an attempted recovery child now fails safely on unreadable data rather than
clearing it. No watchdog stop/trip timing was changed.

The actual CLI restore routine is shared with in-process helper-boundary tests.
The constructor accepts isolated defaults and injected discovery; injected
discovery also bypasses WindowServer connection and private-framework loading.
Tests call that production constructor/routine, not merely the pending predicate.
The pre-fix regression failed at
`unreadable current journal fails production helper initialization before discovery`.
After the fix, tests verify byte/type/metadata preservation, zero discovery on
failure, no partial legacy migration, valid migration, and actual-host refusal of
quit/module unload after the production loading error, even without a watchdog.

Final `bash test.sh`: **4,155 isolated checks**, build, and installer fixtures
passed. `git diff --check` passed. No built CLI, installed app, or live hardware
acceptance was invoked for these journal regressions.

Scope correction: the existing `safeDisplays` test used to construct a real
controller with standard defaults. Earlier full-suite runs inherited that path,
which can discover displays and rewrite record preferences despite not changing
topology. This follow-up replaces it with isolated defaults and fake discovery.
No live preferences were inspected or reverted to investigate that pre-existing
test behavior. All DisplayController constructions in the final test suite now
use isolated defaults and injected discovery. Main and its checklist remain
untouched; independent parent review is still required.

## Boundary follow-up — delayed helper authorization

Entry-time readiness was insufficient while a gesture was draining. Display
commands now carry typed recovery/supervised-mutation permission. The serial
helper executor rechecks main-owned watchdog readiness immediately before invoking
the runner, after both gesture drain and executor queueing. New disables and
arrangement changes require supervision; On/Restore remain independent. Rejected
authorization unwinds the existing completion path without creating a rollback
timer or a snapshot delay, so supervised retry is immediately available.

An actual-host blocked-gesture regression failed before the fix at
`off: dispatch-time watchdog loss blocks only new disables, never On/Restore recovery`.
After the fix it verifies zero Off runner calls, busy reset, retained journal,
immediate retry, and successful On/Restore after watchdog loss. All gestures,
helpers, snapshots, and journals are isolated fakes. Full `bash test.sh` passed:
**4,172 isolated checks**, build and installer fixtures.

## Boundary follow-up — every journal reload and record save

The constructor fix did not protect later refreshes: refresh silently ignored an
unreadable journal, discovered displays using cached records, and saved over the
bad data. Refresh now reloads through the shared throwing loader before any
discovery. Failed reloads retain cached recovery ownership. Every record save
revalidates the stored journal immediately before writing; failed saves preserve
the previous cache, and restoration flags are staged until persistence succeeds.
Injected discovery now applies to repeated refreshes as well as initialization.

The post-initialization regression failed before the fix at
`post-init corrupt/non-Data journal refresh throws before discovery and retains cached recovery authority`.
Tests cover malformed bytes, invalid JSON shape, non-Data values, zero discovery
on bad reload, exact raw-value retention, corruption during fake discovery,
cached-ownership retention, and successful refresh after repair. The shared CLI
restore routine and arrangement recovery also reject post-init corruption.

Audit scope and resulting changes:

- All controller record decoding now goes through `loadRecords`; malformed data cannot be
  silently replaced by cached or empty records on a reload.
- All record saves go through the throwing, revalidating `saveRecords`; the
  legacy migration is separately validated before its existing copy step.
- Helper restore, arrangement apply/recovery, and restore finalization reload
  before using cached ownership. GUI refresh propagates errors without replacing
  its existing controller/model snapshot. The read-only dashboard metadata cache
  remains non-authoritative.
- Pending-arrangement and saved-layout data reads reject non-Data values rather
  than treating them as absent. A wrong-type pending arrangement remains pending
  and recovery throws without clearing it; a regression covers that case.
- All three host helper callers were checked: Off and arrangement require typed
  executor-time supervision; On and explicit Restore use recovery permission.
  The single gesture drain/executor/completion path remains centralized.

Final `bash test.sh` passed: **4,201 isolated checks**, build and installer
fixtures. `git diff --check` passed. These regressions use isolated preferences,
fake discovery/gestures/helpers, and no live device/journal or app launch/quit.
This is not cross-process transactional locking or live hardware acceptance.
Main remains untouched; parent independent review remains outstanding.
