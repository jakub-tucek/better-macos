# Host quit coordination — 2026-10-15

Scope: host action admission and quit attempts only. No feature storage, cleanup,
configuration, navigation or UI redesign.

`HostTransactions` owns preparation order, admission throughout asynchronous
draining, final Mouse/Clipboard/busy checks, reversible cancellation, and lasting
approval. `AppDelegate` supplies concrete feature actions, readiness refresh,
messages and AppKit termination replies. Display recovery keeps its existing
gesture-drain path; feature modules still perform their own restoration.

## Depth checks

- **Deletion test:** deleting the module would put admission transitions, cleanup
  ordering, duplicate/stale callback rejection and cancellation reopening back in
  the host and its tests, not remove that complexity.
- **Locality:** quit phase and attempt identity are private to one module. The
  host no longer exposes partial clipboard-termination helpers to tests.
- **Leverage:** dashboard callbacks and host readiness use the same admission
  decision; focused tests call the same `requestQuit` interface as AppDelegate.
  Named actions describe the existing Mouse, Clipboard, Spaces and display
  variation, not a universal feature adapter registry.

## Coverage and limits

- Full `bash test.sh` builds the app and isolated executable with warnings as
  errors: **3,666 isolated checks passed**, followed by all seven installer
  regression checks. `git diff --check` also passed.
- Focused tests cover initial and final vetoes, blocked drains and late actions,
  display-versus-Spaces ordering, inline completion, reentrant/repeated requests,
  cancellation readiness, stale/duplicate callbacks and approval staying closed.
- `Tests/ClipboardTests.swift` retains real-host blocked gesture-drain,
  cancellation and late mutation tests. Former partial-helper checks now enter
  through `applicationShouldTerminate`, including the final late Mouse recheck.
- No live clipboard, input posting, device-setting changes, window movement,
  application launch/quit or push was used for acceptance testing. Existing
  watchdog/installer tests operate on disposable fixtures. Live acceptance was
  deliberately not attempted. Independent Sol review remains required.
