# Offline gesture terminal failures · 2026-10-16

Status: **three source-level holes reproduced; production fix not authorized**.
Production base: `d7c8da9`. The dedicated `investigate/gesture-terminal-proof`
branch adds only opt-in fixtures and this draft. No vendor production source,
host API or default test-suite input changes. Independent review remains pending.

These proofs do **not** reproduce or explain the user's whole-desktop click
failure. No real gesture delivery, Dock state, WindowServer recovery or hardware
acceptance is established. A fake poster returning true means a fixture call
succeeded, not that the OS received or completed a gesture.

## Commands and observed results

From the isolated worktree, with Apple Silicon / standalone CLT 27 / macOS 26:

```sh
bash Tests/gesture-terminal-proof.sh --characterize
bash Tests/gesture-terminal-proof.sh --require-safety
```

The first command exits 0 when the known holes reproduce. The explicit second
command exits **1**, intentionally red against production. Neither is included
in `test.sh`. Compiler/fixture setup errors exit nonzero; C explicitly refuses
the macOS 27 augmented-payload allocation order rather than claiming coverage.

Observed trace:

```text
CONTROL instant: began/changed/ended posted to fake sink
REPRODUCED instant: allocations=2 posts=1 terminal_attempted=false result=failure
REPRODUCED instant-ended-failure: allocations=3 posts=2 terminal_attempted=true result=failure
REPRODUCED animated: terminal_failures=1 drain_completions=1 reported_failures=0 attempts=10
REPRODUCED interceptor: timestamp_gap_seconds=3600 companion_suppressed=100/100 ordinary_click_passes=true
CONTROL interceptor: cancellation and tap interruption clear suppression
```

### 1. Instant short-circuit skips terminal attempt

The runner compiles the unchanged production `CStrafe.c` and `IOHIDPayload.c`
with a forced header replacing `CGEventCreate` and `CGEventPost`. The allocation
wrapper allocates unposted in-memory events, except the selected failing call;
the posting wrapper only records phases in memory. The runner checks undefined
symbols in both objects and refuses an unresolved live `_CGEventPost` reference.
No production gesture control flow is copied into a test implementation.

`strafe_post_switch_gesture` combines began/changed/ended with short-circuit
`&&`. Fail allocation two: began is fake-posted, changed fails, allocation three
for ended is never attempted. Return value is false. A separate failure at
allocation three confirms that ended itself can fail after earlier fake-posts.
The success control records phases 1, 2, 4.

### 2. Animated terminal failure is invisible to drain

The Swift fixture compiles unchanged `GestureSwitchEngine`. Existing injected
`postPhase` records all attempts and returns false for ended. `spaceInfo` returns
nil, preventing topology queries; quick speed selects only the injected ramp.
A bounded semaphore waits for began, then `cancelPendingSwitches` runs while
that ramp is active. The main run loop is pumped for at most two seconds.

Eight changed attempts plus began and ended produce ten attempts, one rejected
terminal, and one normal Void drain completion. No failure reaches the caller.
The fixture does not infer an OS latch from that rejected fake call.

### 3. Lost physical terminal retains companion suppression

The fixture calls production `SwipeInterceptor.handle` directly with unposted
in-memory events. It never calls `start`, `enable`, or installs any tap.
Injected switch engine does nothing; Exposé closure returns false.

Idle companion passes. A real-source-shaped horizontal began sets tracking.
Without ended/cancelled, 100 companion events at timestamps one hour later all
remain suppressed. An ordinary click still passes. Explicit cancellation and
tap-interruption callbacks each clear tracking in separate controls.

**Clock limitation:** production has no injected clock or elapsed-time check.
The fixture advances event timestamps, not wall time or a new production clock.
This proves that elapsed event time does not clear tracking; it does not prove
that macOS would emit this exact sequence after Bluetooth disconnection.

## Proposed fix contract, approval required

### C: always attempt termination after a successful begin

Replace short-circuit sequencing with explicit results. If began succeeds,
attempt ended even when changed fails. Return failure if any required phase
fails, even if the terminal attempt subsequently succeeds. Do not post changed
or ended when began failed. No unbounded retry, fabricated delivery guarantee
or automatic Dock restart. A bounded terminal retry, if approved separately,
must retain uncertainty and report its attempt/failure counts.

The existing Bool return is insufficient for host recovery decisions. Prefer
an internal structured attempt result, retaining the public Bool compatibility
adapter if needed: began attempted/succeeded, changed failure, terminal
attempted/succeeded. Name success as **post attempt accepted**, never delivered.
Both instant and ramp paths must contribute to the same owner-held uncertainty
state; otherwise the new drain contract leaves instant failures invisible.

### Swift: separate quiescence from terminal-attempt outcome

Proposed `GestureDrainResult`: queue quiescent plus terminal-attempt status
(`notStarted`, `attemptAccepted`, `attemptFailed`), and phase/terminal failure
counts. Completion remains asynchronous and bounded by current queue work,
never waits for OS acknowledgment or main-thread work from the ramp queue.
An accepted terminal after a failed changed remains an operation failure but
does not falsely assert terminal allocation failure. No result proves OS state.

Keep failure sticky on the feature owner across repeated suspend calls; an
empty queue must not erase prior uncertainty. Prevent new interception while
terminal uncertainty is pending. Preserve saved user choice and report a
specific error. Neither a wall-clock timeout nor a fresh watchdog heartbeat
clears uncertainty.

Actual affected call sites:

- `SpacesModule.suspend/stop`: currently discard all phase results, set
  `isDraining=false`, then invoke Void completion. Carry the typed result and
  retain uncertainty before notifying callers; do not equate teardown with repair.
- `AppDelegate.afterGestureDrain` / `runDisplayCommand`: currently execute every
  operation after Void completion. Ordinary supervised mutations must fail
  before helper launch on known terminal failure. **Recovery is an exception:**
  `.recovery` must remain reachable after queue quiescence even if posting failed,
  with the uncertainty still surfaced and retained. Do not gate restore on a
  watchdog becoming ready or a nonexistent terminal acknowledgment.
- Animation changes also call `afterGestureDrain`; explicitly block their
  ordinary mutation path on uncertainty instead of silently proceeding.
- `HostTransactions.QuitActions.suspendSpaces` currently turns completion into
  `complete(true)`. Introduce a separate gesture result/veto, including when
  display recovery runs first. Successful display restoration cannot erase a
  gesture failure. Cancel normal quit on known terminal failure, reopen host
  admission and keep recovery/retry controls available. Reopening must not
  automatically restart interception under the retained uncertainty.
- Disable/unload paths must preserve the owner or transfer its pending failure
  before releasing it. `applicationWillTerminate` is too late to own a new veto.

This needs coordinated owner/host tests before implementation: failed terminal
blocks supervised display launch and normal quit, recovery still launches after
quiescence, failed quit reopens admission without rearming interception, repeated
drain retains failure, and callbacks complete once without queue/main deadlock.
Whether an explicit user override for normal quit is acceptable is a product
safety decision, not implicit authorization in this investigation.

### Interceptor: preserve real terminal forwarding

Do not blindly clear state and swallow the next physical terminal, or treat a
timer as proof that Dock is repaired. Keep physical-stream suppression state
separate from synthetic-terminal uncertainty. A bounded stale-tracking policy
could release companion suppression while retaining a minimal stale-stream
record used to process a late real terminal correctly. Existing successful
IOHID-payload handling forwards a motion-cleared real ended; retain that contract.

Before selecting a timeout, add an injected monotonic clock and callback replay
tests for stale began, late ended/cancelled, synthetic source, vertical gesture,
new began, tap interruption and disable/re-enable. Specify handling of a late
terminal without double-switching. Do not infer a safe timeout or OS repair
from this one-hour event-timestamp proof. No timer-based production policy is
approved here.

## Scope and validation limits

Runner uses temporary compiler outputs with invocation-owned cleanup. No app
bundle is built, signed, installed, launched or quit. No Bluetooth command,
real event post, tap installation, permission prompt, preference write, signal,
watchdog action, Dock restart or WindowServer operation is invoked. Vendor
`Preferences.swift` is compiled only to resolve unused transition persistence
methods; the fixture never accesses its lazy store or persistence methods.
The OS/frameworks still allocate in-memory CGEvent objects.

Only focused fixtures and shell/whitespace checks were run. Full tests, lint,
independent review, production fix and native acceptance remain outstanding.
Vendor provenance remains unchanged because no vendor source was patched.
