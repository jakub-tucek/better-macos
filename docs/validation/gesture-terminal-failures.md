# Offline gesture terminal failures · 2026-10-16

Status: **C instant terminal-attempt fix independently reviewed CLEAN and integrated**;
see [main evidence](#main-integration--2026-10-16). Source-worktree records below
retain their historical review status and tested source state.
Swift drain reporting and stale physical tracking remain unchanged and unsafe in
the isolated proofs. Whole-desktop freeze cause remains unresolved.

## Approved narrow C fix

After a successful began, `strafe_post_switch_gesture` attempts changed and ended
separately, then returns `changed && ended`. Failed began returns false without
continuation. Failed changed no longer skips ended. Failed ended still returns
false; no retry or delivery acknowledgment is introduced. Public Bool signature,
direction constants, successful phase order and event properties are unchanged.
Vendor provenance is updated; vendor and project license contents are unchanged.

`GestureSwitchEngine.post` already returns this C Bool on the instant path.
Both topology branches of `switchSpace` throw `postFailed` when it is false;
predictions are not advanced. `SwipeInterceptor.fire` catches that error, leaves
`swipePosted=false` and logs it. This narrow fix adds no retained uncertainty or
host failure result: instant partial failures still are not conveyed by later
Void drain completion. Animated posting still ignores phase Bool results.

Current commands:

```sh
bash Tests/gesture-terminal-proof.sh --instant-safety # default; exits 0
bash Tests/gesture-terminal-proof.sh --characterize   # C green; known Swift holes reproduced, exits 0
bash Tests/gesture-terminal-proof.sh --require-safety # explicitly red for remaining Swift holes, exits 1
```

`test.sh` runs only `--instant-safety`. It checks **114 assertions** across both
directions: successful order/properties, failed began without continuation,
failed changed followed by ended with a false overall result, and failed ended
with no retry. C production/fixture units compile with `-Wall -Wextra -Werror`;
the no-live-post object-symbol guard remains active. Pre-27 allocation-path
coverage only; the fixture refuses the augmented macOS 27 path.

New regression against the original C source from `21ec11a`, compiled in an
invocation-owned temporary directory with the same fake poster, exits 1:
**114 checks / 4 failures** (missing terminal continuation and phase order, both
directions). Against the patched source: **114 checks / 0 failures**. Remaining
Swift characterization is unchanged; explicit `--require-safety` still exits 1.
No deliberate-red mode is included in the default suite.

### Narrow-fix validation

Tests ran in this isolated worktree, based on `21ec11a` with the C/fixture changes
uncommitted; the build therefore records that base revision and modified source
state, not a falsely clean loaded/frozen revision. No production or test inputs
changed during the final full run. Evidence logs remain ignored under `build/`.

- Original source plus new C regression: 114 checks, four failures (red).
- Patched focused C regression: 114 checks, zero failures (green).
- Remaining Swift/interceptor safety mode: still exits 1 by explicit request.
- Pinned SwiftLint: zero violations across 61 files. Pinned SwiftFormat: 0/61
  require formatting. Offline developer-tool regressions passed.
- Shell syntax and `git diff --check` passed. Production C and fixture C compile
  with `-Wall -Wextra -Werror`; public C headers and license contents are unchanged.

Initial full run failed after successful app compilation, bundle signing,
signature/notices/relocation checks and several compiler fixtures: adding the C
regression to `test.sh` required adding its name to `Tests/build.sh`'s subprocess
stub list. That fixture intentionally has fake compiler outputs, not real vendor
C sources. The scoped stub-list correction preserves the real default C check
while keeping the compiler-input fixture isolated. Original failed evidence is
`build/gesture-terminal-full.log`; the subsequent complete-run evidence is
`build/gesture-terminal-full-rerun.log`. This failure is not hidden or counted as
a passing full run.

The corrected final full run completed successfully (exit 0; existing process
exit event and harness completion received). Command:

```sh
MAC_UTILS_SIGNING_IDENTITY=- DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  GESTURE_PROOF_TMPDIR=/private/var/folders/01/q8lbfsh16d9bjtl88bpwtr840000gn/T/opencode \
  bash test.sh
```

Separate totals, not combined or substituted:

| Check | Result |
| --- | --- |
| Legacy isolated checks | 4,633 passed |
| Diagnostics review regressions | 81 passed, plus safety-entry source guard |
| New C instant-terminal regression | 114 assertions passed |
| Swift Testing policy | 10 tests in 3 suites passed |
| Mocked installer scenarios | 13 passed |
| Build/compiler fixtures | Passed, including app/legacy archive and fresh-object input checks |
| Real/relocated built bundle | Complete notices/provenance, metadata/dependencies and strict ad-hoc signature verification passed; not launched |

The compiled artifact identifies base `21ec11a` with modified source inputs.
The later commit captures the tested implementation/fixture tree, with evidence
prose added after execution; this is not a claim that artifact embeds that later
commit. The initial failure remains preserved in its separate log.

Lint/format/tooling evidence: `build/gesture-terminal-{lint,format,tools}.log`.
No app was launched, installed, quit or relaunched. No live event post, tap
installation, Bluetooth action, Dock/watchdog signal or TCC modification occurred.
Independent review and native/hardware acceptance remain pending.

## Main integration · 2026-10-16

The parent supplied independent **CLEAN** review of the narrow C change and offline
proofs: **114 C assertions passed**, original-source negative control had **four
failures**, and allocation/release balance was **14/14**. Those are reviewer results,
separate from the integrated run below; no live incident recovery was established.

| Reviewed source | Main commit |
| --- | --- |
| `21ec11a` — offline terminal-failure proofs | `3569037` |
| `3d59d3c` — unconditional terminal attempt after successful began | `cd811ea` |

Both unique commits integrated in order, without conflicts, on `d7c8da9`.
Pre-existing untracked `.worktrees/` work was preserved. Pending Bluetooth branches
were not integrated. Production app Swift, vendor Swift/interceptor, public C
headers, payload implementation, license contents and host quit/admission contracts
are byte-identical to prior main. Only the vendored C sequencing changes production
behavior; this remains a compiled source dependency, not a runtime plugin.

At **`cd811eabd366e11b60b5322b89c7e72829fff5b3`**, one full standalone CLT
`bash test.sh` run passed these separate totals:

| Check | Integrated result |
| --- | --- |
| Legacy isolated | **4,633**, including 37 presentation and 27 Activity checks |
| Diagnostics | **81**, plus no-flush/no-sync-wait safety source guard |
| Offline C terminal regression | **114 assertions**, zero failures |
| Swift Testing policy | **10 tests / 3 suites** |
| Mocked installer | **13 scenarios** |
| Build/compiler and real/relocated bundle | Passed, including explicit C inputs, static Clipboard policy ownership, complete notices/provenance and strict configured-certificate signature |

The 114 C assertions are not included in or added to the legacy count. Log:
`build/gesture-terminal-integration-clt.log`; it records HEAD, scoped standalone
CLT compiler/SDK paths, Swift 6.4 / SDK 27.0, arm64 and explicit unset `SDKROOT`.
Source/built plist lint and metadata passed: version `0.4`, build `4`, arm64/macOS
15+, SDK 27.0 and embedded revision equal the exact tested source above.

Unmodified pinned lint/format passed across **61 files**, without rule/baseline
changes or rewrites. Offline tooling and CI whitespace fixtures passed. Logs:
`build/gesture-terminal-integration-{lint,format,tools,ci}.log`.
Production/tests/vendor inputs exactly match the reviewed source branch.
All **16 shell inputs**, **257 local links and 48 fragments across 34 tracked
Markdown documents**, compiler-input ownership assertions and `git diff --check`
passed. Tooling, CI, lint baseline and all prior app Swift inputs are unchanged.

Separate offline `--characterize` completed with exit 0 and reproduced ignored
animated terminal failure (one failure, one Void drain completion, zero reported
failures) and 100/100 suppressed companion events at one-hour-later timestamps;
ordinary clicks still pass. Explicit opt-in `--require-safety` exited **1**, as
expected, with the C regression still green. Logs:
`build/gesture-terminal-integration-{characterize,require-safety}.log`.
Only C safety runs in the default suite. Neither these proofs nor a successful
post attempt establish delivery, Dock repair or the cause/fix of the desktop incident.
No Swift result contract, interceptor timeout, persistent marker or new quit veto
was implemented; later design below remains unapproved.

No production app launch/quit/relaunch/install, live input posting/tap, Bluetooth or
device action, preference/permission/TCC change, Dock signal, push/tag or publication
occurred. The current running app was preserved; rebuilding the on-disk bundle does
not update its loaded image. Hardware/live acceptance remains open. The separate
evidence-only commit does not claim an artifact rebuilt at its own revision.

## Next design, not approved for implementation

The earlier normal-quit-veto proposal below is superseded. Missing OS
acknowledgment is inherent to every `CGEventPost` and is **not** a failure state
or reason to trap normal quit. A concrete false posting result is distinguishable
from that universal lack of acknowledgment.

Narrow options for a later change:

1. **Owner-only reporting:** record concrete phase failure and expose a typed
   drain result without changing quit approval. Keep interception paused on a
   concrete terminal failure; retain normal quit and display recovery. Smallest
   host-policy change, but quit does not require explicit acknowledgment of the
   warning. Existing Mouse/Clipboard/display restoration checks still apply.
2. **Explicit quit choice, preferred for planning:** after queue quiescence, show
   the concrete post-failure warning once per quit attempt with **Cancel** and
   **Quit anyway**. Cancel reopens host admission but does not rearm interception.
   Quit anyway bypasses only the gesture warning, never other restoration/veto
   contracts. No permanent gesture veto or automatic restart. Existing asynchronous
   quit reply must still complete exactly once, including cancellation/reentrancy.

Both options require a typed result distinguishing no gesture started, terminal
attempt accepted, and concrete terminal attempt failed, plus phase failure
counts. No status means delivered or Dock repaired. Keep ordinary supervised
display/animation mutations blocked on a known terminal failure, but allow
display recovery after queue quiescence regardless of that failure or watchdog
readiness. Do not wait for an OS acknowledgment that does not exist.

The current instant C Bool does not identify the failed phase: false can mean
failed began, failed changed with an accepted terminal, or failed terminal. A
later Swift result must label that `instantPhaseFailureUnknown`, not invent a
known terminal failure. Initially scope precise terminal accounting to the ramp,
or separately approve an internal C detailed-result seam while preserving the
existing public Bool adapter. The current patch adds neither API nor phase status.

Lifecycle proposal: the host retains a session-scoped gesture failure owner
outside optional `SpacesModule`, keyed by attempt/generation, so unload cannot
erase it. Disable/unload removes the tap and drains work, preserving the failure
and saved feature choice. Re-enable is refused while a concrete terminal failure
remains unresolved. Do not clear it on another empty drain, watchdog heartbeat,
timeout, successful display restore or an accepted retry. A bounded terminal
retry may report a newer attempt but cannot certify OS recovery. User escape is
normal quit (option 1) or explicit Quit anyway (option 2), with no automatic
relaunch. Ending the process is not proof that Dock state recovered. For a later
patch, prefer a durable activation-inhibit marker so even a new process cannot
silently rearm the saved interception choice. An explicit user acknowledgment
could authorize a new attempt/generation while retaining the failure record;
it acknowledges risk, not OS recovery. The precise reset UI and persistence
contract need approval before implementation. No new persistent marker,
automatic live retry or restart is part of this narrow patch.

Before implementing either option, approve warning/escape semantics and test
real owner retention across unload/reload, both quit branches (including display
recovery first), callback-once behavior, admission reopening, no automatic
reactivation, and recovery availability. The interceptor timeout policy remains
separate and unapproved; late real-terminal forwarding must be preserved.

## Historical initial proof and proposal · `21ec11a`

The following records the original red baseline and earlier proposal, not the
current runner modes or approved quit policy.

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

## Historical proposed fix contract, superseded where noted above

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
