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
