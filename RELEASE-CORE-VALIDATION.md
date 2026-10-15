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
