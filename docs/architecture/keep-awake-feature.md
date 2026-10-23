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

## Keep awake action palette

`KeepAwakePalette.swift` is another presentation of the existing feature callbacks,
opened from the right-click menu. It offers existing duration presets, the existing
custom-duration editor, display-awake control, extension, end/retry and app-rule
resume. Its action seam validates current UI eligibility; `KeepAwakeFeature.perform`
still checks host admission and owns assertion changes. End session permits normal
sleep and pauses current app rules; it does not invoke immediate system sleep.

The Windows and Keep awake palettes share `ActionPalettePresenter`,
`ActionPaletteLayout` and `ActionPaletteTile`. The shared module owns native
nonactivating presentation, screen bounds, material and observer cleanup, not feature
state or action policy. Closing a palette does not end its feature session. Host
surface switches and quit quiescence dismiss the panel.

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

## Implementation verification · 2026-10-15

Source: `d1ec4bb23de5382654fe826ad3639099df529850`, based directly on reviewed source
organization `49b6398ee5a8feb7deb0a7f7434e98b344d902fa`, isolated branch
`keep-awake-feature`. This is implementation evidence, not independent review or
integration approval.

On macOS 26.6.2 (`25G83`), arm64, with scoped Xcode 27.0 (`27A266a`), Apple Swift
6.4 (`swiftlang-6.4.0.34.1`), SDK 27.0 and Swift 5 language mode, with `SDKROOT`
explicitly unset and `BETTER_MACOS_SIGNING_IDENTITY=-`:

- Full `bash test.sh` passed: **4,366 legacy isolated checks** (31 more than the
  reviewed base), **10 Swift Testing tests in three suites**, **13 mocked installer
  scenarios**, production state compiler fixture, explicit source/package/link
  ownership and build-failure/rollback fixtures, plus real/relocated signed-bundle
  checks. These are full suite executions using existing worktree build outputs,
  not a claim of another clean standalone-CLT suite.
- Pinned SwiftLint and SwiftFormat passed across **47 files**, without rewrites;
  bootstrap verified tool hashes/versions and offline tooling regressions passed.
- Standalone CLT 27's production `StoredState` compiler fixture passed separately.
  A warnings-as-errors CLT/SDK 27 typecheck passed for all **37 explicit production
  Swift inputs** (33 app, four vendor), importing the existing ClipboardPolicy
  module and never recompiling its policy source. This does not establish the
  declared minimum Swift 6.0 toolchain or another complete CLT app/test run.
- Strict ad-hoc signature verification, source/built plist lint and artifact
  metadata passed: arm64, macOS 15.0 minimum, SDK 27.0, version `0.4`, build `4`,
  embedded source revision above. Complete project/vendor/upstream notices,
  relocated signature/metadata integrity and absence of dynamic policy/Testing
  dependencies passed. No bundle was launched.
- Both explicit source lists preserve all prior inputs/order and add each new
  production file exactly once. Compiler-input fixtures check both new files in
  app and legacy invocations. The existing owner implementation, HostTransactions,
  Clipboard policy/native implementation, Audio/Bluetooth implementations and
  production UI/setup and host transaction regression files are byte-identical to
  the reviewed base. No source moves, package/vendor/resource changes occurred.
- All **11 shell inputs** passed `bash -n`; **212 local destinations and 33
  fragments across 27 Markdown files** and `git diff --check` passed.

Logs are under
`/private/var/folders/01/q8lbfsh16d9bjtl88bpwtr840000gn/T/opencode/`:
`keep-awake-feature-d1ec4bb-validated-test.log`,
`keep-awake-feature-d1ec4bb-{lint,format,tools,clt-state,clt-typecheck,metadata,static}.log`
and `keep-awake-feature-bootstrap.log`. The known SwiftPM native-engine
deprecation warning remains visible. Earlier logs are retained: the first
precommit compile rejected a source edited during compilation; an initial
post-suite diagnostic wrapper used the wrong executable filename for `lipo`.
The full suite itself passed before that diagnostic error; corrected metadata
checks derive `CFBundleExecutable` from the plist, and the final suite wrapper
completes independently. Neither interruption was an implementation test failure.

At this implementation record, independent review was required before merge. No real app launch/quit/install,
live preferences, clipboard/device changes, TCC changes, version bump, tag/push
or publication was performed. Existing native/hardware and final release gates
remain open; the evidence-only commit does not claim a rebuilt final artifact at
its own revision. Existing guides are intentionally left for the parent integration
to update alongside its independently reviewed work.

## Main integration · 2026-10-15

Independently reviewed CLEAN source commits `d1ec4bb` and `eff835f` integrated
without conflicts as `d45ae21` and **`aec5532f5067eedee417b3cdbaad6a8ba266535e`**,
on main `dc26aa2`. The equivalent source moves were already integrated and were
not cherry-picked again. Current CI configuration and organized paths are retained;
the parallel Settings scrolling investigation is outside this integration.

At that integrated revision, one complete `bash test.sh` passed **4,366 legacy
checks**, **10 Swift Testing policy tests in three suites**, **13 mocked installer
scenarios**, production state compiler, source/package/link/rollback fixtures and
real/relocated signed-bundle notice/dependency checks. Log:
`build/keep-awake-feature-integration.log`. It records HEAD, command-scoped Xcode
27 / Swift 6.4 / SDK 27.0 paths/version, arm64 and bundle metadata with `SDKROOT`
explicitly unset. The known SwiftPM native-engine deprecation warning remains.

Strict configured-certificate signature, source/built plist lint and metadata passed:
the arm64/macOS 15+ bundle embeds the tested revision, version `0.4`, build `4`, SDK 27.0.
Lint/format passed across **47 files**; offline tooling and CI whitespace fixtures
passed. Logs: `build/keep-awake-feature-integration-{lint,format,tools,ci}.log`.

This is **one concrete owned feature**, not a general framework, new package or
universal quit lifecycle. Host admission, preferences, status coordination and quit
authority remain intact; SwiftPM policy ownership, `StoredState` and three explicit
C objects remain unchanged. Historical failures/counts and native/hardware limits
remain revision-bound. No Settings UI source, real app launch/quit/install, live
preferences/devices/permissions, version, push/tag or publication was changed.
This evidence-only commit is not a final artifact at its own revision, another
full CLT run, minimum-toolchain proof or hosted CI execution.

All **13 shell inputs**, **233 local links and 37 fragments across 28 Markdown
documents**, compiler-path/one-time-link assertions and `git diff --check` passed.
Direct comparisons confirm Settings UI/setup views, the original assertion owner,
HostTransactions, Clipboard/Audio/Bluetooth implementations, package and CI inputs
are unchanged. The parallel scrolling defect remains outside this work's acceptance.
