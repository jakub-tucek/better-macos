# Keep Awake owned feature

This is a concrete app-compiled module, not a universal lifecycle framework or
another SwiftPM target. It builds on the reviewed [source organization](../validation/source-organization.md)
at `49b6398ee5a8feb7deb0a7f7434e98b344d902fa` and the existing
[registered choice preparation](builtin-registration.md).

## Ownership and interface

[`KeepAwakeFeature`](../../Sources/Features/KeepAwake/KeepAwakeFeature.swift)
privately owns the typed factory, optional `KeepAwakeModule`, owner callbacks and
snapshot construction. Its feature-local `Action` enum covers existing user
operations; it is not an event bus. Its `State` contains owner availability and
the existing dashboard values, without exposing the owner or arbitrary operations.
All feature operations and state reads require the main thread.

- `reconcile(enabled:)` constructs/activates once when needed and publishes typed
  state. Disabled startup constructs nothing. Re-enable calls the factory again;
  persisted choices survive but a timed session is never restored.
- `perform(_:)` checks injected host admission, uses the existing owner operation,
  and preserves error/publication ordering. Duration changes retain their existing
  setter-only publication; invalid durations remain inert.
- `prepareDisable()` contains the sole disable preparation algorithm: deactivate
  the existing owner; on failure, reactivate that same owner and return the
  original failure. Failed assertion IDs and retry state remain feature-owned.
- `configureForSetup(minutes:display:apps:)` checks admission and delegates to the
  existing complete-policy replacement operation. It reports the original outcome
  without starting a timed session or reimplementing assertion policy.
- `shutdown()` preserves best-effort deactivation. It neither approves nor vetoes
  quit and does not discard an owner holding failed assertion IDs.

The host must prepare a disable successfully, commit its enabled preference, then
reconcile. Reconciliation and preparation are internal host continuations, not new
public user actions: they do **not** recheck admission. A previously admitted
asynchronous choice change elsewhere can still reconcile after admission closes.
Disabling detaches callbacks; saved callbacks check owner identity and generation,
including when an injected factory returns the same owner on a later activation.

[`KeepAwakePresentation`](../../Sources/Features/KeepAwake/KeepAwakePresentation.swift)
is the app-shell adapter. It installs Dashboard callbacks, projects typed state,
and owns app-selection presentation through an injected chooser. Choosers run and
complete on the main thread. Selection results enter `perform` separately, so
admission is rechecked after a modal chooser and for every selected app. Bindings
hold the feature weakly; owner callbacks and the feature's presentation sink also
avoid retention cycles. No new teardown policy is added in an adapter deinitializer.

## Host responsibilities retained

[`AppDelegate`](../../Sources/App/AppDelegate.swift) retains its existing typed
factory injection for callers/tests, but passes it into the feature instead of
storing or accessing a Keep Awake owner. It composes the presentation adapter and
keeps native status-item image/tooltip coordination and module-status publication.
Diagnostics read typed state. `updateModules` calls feature reconciliation at the
original position; setup invokes typed feature configuration.

[`BuiltinChoicePreparations`](../../Sources/App/BuiltinChoicePreparations.swift)
holds a typed `KeepAwakeFeature` slot. The former `KeepAwakeChoicePreparation`
wrapper is removed, not retained as a second disable implementation. Clipboard
and shared Displays preparations are unchanged.

Host admission, enabled-preference commits, setup staging/rollback and outcome
sequencing remain in the host. [`HostTransactions`](../../Sources/Core/HostTransactions.swift)
retains every quit ordering, drain, final check, veto and reopening rule. No awake
quit veto is added. Shared Audio/Bluetooth ownership, display recovery and
readiness, and Clipboard capture/retention/unload/quit distinctions are unchanged.

## Regression contract

[`Tests/KeepAwakeFeatureTests.swift`](../../Tests/KeepAwakeFeatureTests.swift)
exercises the feature interface with isolated preferences, fake assertions and
disabled automatic updates: inert construction, construction-once, closed-admission
continuations, every blocked action, missing/blocked setup, release failure/retry,
reload, stale callbacks (including reused owners), cleanup retention, publication
ordering, setup failure/retry, deadline/app-pause preservation and object lifetimes.
Actual host Dashboard callbacks exercise injected chooser results across closed
admission, rejected Setup Finish/disable, canceled-quit reopening and unchanged
host approval without an awake veto.

Existing production UI/setup disable-failure/retry tests remain in
[`Tests/UITests.swift`](../../Tests/UITests.swift), alongside duration, setup
staging and assertion-failure coverage. Existing host drain/final-check, Clipboard,
shared Audio/Bluetooth and display-recovery tests remain intact. Both explicit
app/test source lists include the two new feature files; SwiftPM still exclusively
compiles ClipboardPolicy. No source moves, package changes or vendor changes occur.

These are isolated regressions, not physical sleep/assertion acceptance or live
app/chooser interaction. Existing [native/hardware gaps](../validation/README.md)
remain open. Revision-bound execution evidence is recorded separately below.
