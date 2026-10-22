# Windows verified execution

`WindowExecution<Access>` implements the existing `WindowPositionBackend` interface.
It owns whole-desktop discovery, the native-identity token cache, the 750 ms scan
budget, per-element 50 ms timeout setup, conservative geometry support, fresh
title/identity checks, same-app destination collision refusal, focused lookup and
last-moment focus recheck, position–size–position writes, and exact readback.

`WindowNativeAccess` is the low-level seam. Its associated element, focus, inventory
entry and write-payload types keep AX/CG types out of execution. The native adapter
reads AppKit/AX/CG facts, decodes values, compares native identities and performs
single attribute writes. It does not choose eligibility, correlate windows, retain
tokens, sequence writes or decide success. Inventory bounds decoding stays lazy
within the measured scan, rather than moving it ahead of the budget.

`AXWindowPositionBackend` specializes that same execution module. Existing default
construction, injected `permissionCheck`/`windowInfo` construction and inherited
static geometry helpers remain available. Permission denial and inventory failure
still return before application enumeration or native AX access. A shared guarded
AX frame decoder replaces the two former decoding sites; the lint baseline shrinks
from four forced casts to two, without a broader suppression.

The interface is the test surface: `Tests/WindowExecutionTests.swift` supplies an
in-memory access adapter and invokes the actual production backend operations.
The adapter stores facts, emits primitive read/write traces, injects time/failures
and simulates resize constraints. It contains no discovery or verification policy.
Tests cover complete-domain failure, budget boundaries, ambiguous geometry/titles,
native equality versus handle replacement, collisions, focus races, write ordering
and short-circuiting, resize-induced repositioning and exact/constrained readback.
Existing coordinator tests and read-only native-constructor regressions remain.

## Ownership and unchanged limits

Host admission stays host-owned. `WindowPositions` retains saved-layout matching,
collision-free planning, exclusions, display/readiness/generation guards and queued
turns. The shortcut session below uses the same backend, without duplicating its
geometry correlation, identity checks or verified write policies. Bluetooth,
preferences, source packages and vendors remain unchanged.

## Shortcut session

`WindowShortcutSession` owns registration attempt suppression, explicit retry,
registration generations and stale callback rejection together with action outcome
state and original-frame lifetime. It remembers the first frame before an attempted
move, even a failed/partial one. At 64 entries it evicts the lexically smallest token,
preserving the previous deterministic policy rather than introducing LRU. Successful
restore consumes the frame; invalidation keeps frames; stop clears them. Destination
and changed-display fitting still use `WindowShortcutAction.destination`.

`WindowPositions` keeps the existing UI properties, opt-in preference and constructor.
It projects session state, supplies current host/readiness/permission admission and
exclusions, and explicitly cancels queued layout restoration immediately before a
manual move. The session rechecks admission and its generation after discovery;
re-registering does not authorize an old callback or an invalidated action.

`WindowShortcutPresetRegistration<Native>` owns the all-or-nothing preset, acquisition
order and cleanup: clear callback, release acquired keys in registration order, then
remove the handler. Even a resource returned with a failing status is cleaned up.
`CarbonWindowShortcutAccess` owns only Carbon primitives and the C event trampoline.
The existing `WindowShortcutRegistration()` name specializes that production
orchestration for Carbon. A deterministic primitive adapter exercises the same
orchestration in tests, with no live key registration. The existing whole-registration
owner fake remains useful for host integration tests.

Whole-desktop fail-closed discovery remains deliberate, including unreadable apps
that the coordinator later excludes. Discovery retains its original deferred
cache replacement, including partial caches on a thrown incomplete scan; moves
still require a successful fresh scan and identity validation before writing.
The budget is checked before apps/windows, not after every native call. An in-flight
call can overrun, including the final read. No hard preemption or end-of-scan check
is added. Write refusal can leave a partially moved/resized window; there is no
transactional rollback. Exact-title reuse and native timeout enforcement retain
their [existing acceptance gaps](../validation/window-positions.md).
