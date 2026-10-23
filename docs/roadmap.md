# Development roadmap

Plan started at `2620a32` (2026-10-15); current source checked through `d6b216f`
on 2026-10-23. Implementation status is separated from acceptance below.
Pinned developer tooling, the first Clipboard policy SwiftPM slice and partial static
built-in registration, mechanical source organization and a CI workflow are available;
one concrete Keep awake owned-feature seam is also implemented; broader lifecycle
extraction remains proposed. Hosted CI execution is unverified. Current behavior lives in
[the usage guide](usage.md); ownership lives in [the source map](modules.md), and
acceptance/failures in [validation](validation/README.md). No release date or tag is promised.

## Recent implemented work

- Tabbed Settings and a quieter editable popup, with responsive Displays/Windows layout.
- Shared headings, neutral cards, icon badges and launch rows across Quick actions,
  Settings, setup, right-click menu and palettes; adaptive widget galleries.
- Opt-in Rectangle-style window shortcuts and a captured-target Window actions palette.
  Repeated left/right halves now traverse neighboring displays with opposite-half entry.
- A retained right-click panel and Keep awake palette using shared presentation/tiles.
- Verified Windows execution/native-access and shortcut-session boundaries; deterministic
  Bluetooth cycle delivery. These deepen existing owners, not a general framework.
- Foreground-only shortcut discovery; named layouts retain full-desktop fail-closed scans.

See [recent UI/shortcut evidence](validation/ui-window-shortcuts.md) and
[window execution](architecture/window-execution.md). Live keyboard/focus, display
movement, sleep, VoiceOver and right-click smoothness remain acceptance work.

## Priorities

| Priority | Work | Done when |
| --- | --- | --- |
| 0 | Finish release safety | Core fixes and watchdog/corrupt-journal regressions are reviewed and integrated through `dc96e9c`; complete native acceptance and record remaining hardware gaps at the tested revision. |
| 1 | Documentation and developer baseline (partial) | Documentation consolidation and pinned tools/commands are implemented; CLT 27/Xcode 27 compatibility is verified. Establish a tested minimum toolchain. |
| 2 | One SwiftPM slice and source organization | Clipboard policy is extracted and statically linked with named tests; first-party Swift is organized by owner under Sources without lifecycle changes. Preserve app/helper behavior and packaging; toolchain evidence remains revision-bound. |
| 3 | Built-in feature registration (partial) | Metadata/choice preparation and one concrete Keep awake private-owner/presentation seam are integrated. Other factory/lifecycle extraction and a general framework remain pending; preserve IDs, shared ownership and drain/veto behavior. |
| 4 | Test migration and CI (partial) | Arm64 preview workflow and offline CI regressions are configured; hosted execution is unverified and branch protection is not configured. Continue suite migration and clean/incremental verification. |
| 5 | Native UI automation, if needed | Add a separate full-Xcode GUI job only for acceptance gaps that require app-driving tests. |
| Later | Measured performance/storage work | Compare idle resource baselines; consider SQLite only if clipboard measurements justify migration. |

Priority 0 remains open for native/physical acceptance and final release gates.
The [Bluetooth observation/control split](architecture/bluetooth-observation.md)
adds bounded read-only comparison and conservative helper-control admission;
it does not qualify live radio control, explain the helper/native disagreement,
or close the whole-desktop freeze incident. Native fixture coordinate correction
is isolated test evidence, not physical interaction acceptance.
Display-recovery ownership, setup awake-assertion removal, watchdog authorization
and corrupt-journal preservation fixes are independently reviewed CLEAN and integrated. Use
[release evidence](releases/checklist.md#current-evidence) and
[UI acceptance](validation/ui-replacement.md), not test counts, to close these gates.

## Build and source boundaries

- Implemented: **one local Swift package** for [Clipboard policy](swiftpm.md),
  with sole SwiftPM compilation ownership and static app/legacy-test linking.
  Future extraction should use meaningful targets for policy/backends and C boundaries;
  avoid a target per file or a package per feature. Reuse existing backend seams.
- Keep `build.sh` as the app-bundling entry point: plist/revision metadata, resources,
  complete licenses, signing verification and replacement rollback remain its job.
  Preserve the Apple Silicon/macOS 15+ CLT source-install path without full Xcode.
- Put C integration behind explicit C targets for MouseHID and vendored payloads;
  keep `Vendor/` contents and notices unchanged during this refactor.
- Implemented: mechanical first-party Swift organization below, without treating
  directory names as package boundaries. MouseHID remains the unchanged manual C
  boundary; exposing it through a package target is still proposed:

```text
Sources/
  App/          # entry points, composition, setup and native host integration
  Core/         # host transactions, recovery/readiness and shared policy
  Features/     # Displays/, Audio/, Bluetooth/, Clipboard/, Mouse/, ...
  SharedUI/     # Settings shell, widgets and shared controls
MouseHID/       # unchanged C boundary; package target remains proposed
Vendor/        # existing pinned sources and notices
Tests/         # named suites plus shell/process fixtures
docs/          # current guides and revision-labelled evidence
```

Verify resources and helper/watchdog launch from the **installed, relocated bundle**.
Record source revision, SDK/compiler, dependency inputs, architecture and signing
mode for release reproducibility; do not claim byte-identical output across SDKs.

## Reusable modules: static registration first

- Implemented: [inert presentation catalog and typed choice preparation](architecture/builtin-registration.md)
  for Keep awake, Clipboard and shared Displays, preserving persisted IDs and
  preference keys. Keep awake now uses a [concrete owned feature and presentation adapter](architecture/keep-awake-feature.md);
  other owners remain explicitly host-composed. Host admission, choice commits,
  setup sequencing and quit remain authoritative; no general lifecycle framework is complete.
- Keep feature-specific operations behind existing interfaces. Preserve asynchronous
  drains, cleanup failure/retry and unload/quit vetoes; `HostTransactions` retains
  action-admission and termination authority.
- Keep one Audio owner shared with Bluetooth and shared Displays recovery reachable
  when individual display features are disabled. Registration must not duplicate them.
- The first seam is covered through actual UI/setup failures and retries for Keep
  awake, Clipboard and Displays. Broader lifecycle/factory extraction requires another
  reviewed slice; avoid universal `start/stop` adapters and a generic event bus.
  Preserve disabled-feature teardown and shared-dependency regression coverage.
- Aim for reusable **build-time packages** after that proof. External runtime plugins,
  discovery, ABI compatibility and third-party code loading stay outside this plan.

## Tooling, tests and CI

- Implemented: [developer commands](development.md), repository-local verified
  SwiftLint **0.65.1** and SwiftFormat **0.63.1**, non-mutating checks, narrow lint
  baseline, `.editorconfig` and offline tooling regressions. The standalone CLT 27.0
  `StateMacro` failure is resolved through the explicit public `StoredState` wrapper;
  [combined clean CLT/Xcode evidence](validation/clt-compatibility.md#combined-main-integration) is recorded at `dff0491`.
  The first SwiftPM policy slice and ten named tests in three suites are implemented;
  mechanical source organization is implemented; further suite migration remains pending. The configured
  [CI workflow](ci.md) has **hosted execution unverified**; branch protection is not
  configured and the tested minimum toolchain remains open.
- Document a tested compiler/SDK baseline. Today's scripts use Swift **5 language
  mode**; that differs from a Swift **6 toolchain**. The package declares tools 6.0
  and uses Swift Testing; only Apple Swift **6.4** has been validated here, including
  standalone-CLT policy tests. A working minimum-toolchain app build remains unproven.
- Preserve pinned development-only tool versions, version-checked bootstrap and
  `.editorconfig`. Expand the narrow ruleset only in reviewed increments; exclude
  vendor, build and generated files and review baseline exceptions. CI checks
  must not mutate files; keep formatter rewrites separate from architecture changes.
- Replace the monolithic test runner incrementally with named independent suites
  using Swift Testing where supported. Keep XCTest for UI/performance tests.
  Use `@MainActor` for AppKit tests, isolated preferences/temp directories and fake
  clocks; serialize unavoidable shared state rather than racing global fixtures.
- Keep shell packaging/installer tests and watchdog subprocess tests as distinct
  suites. Keep live OS/hardware mutation opt-in and outside default unit checks.
- Implemented: `test.sh` links only three explicit owned C objects and the policy
  archive; fixtures reject stale objects, duplicate policy inputs and missing package
  outputs. Continue clean/incremental-build checks as more code moves.
- Implemented: CI selects the official `xcode-27` arm64 preview, pins checkout/log
  actions and asserts architecture/compiler/SDK before existing checks. Committed
  PR/push/manual whitespace ranges have offline fixtures and full-history checkout.
  Local validation is not proof of hosted scheduling, GUI feasibility, a green
  remote suite or required branch checks; record an authorized hosted run separately.
- Add XcodeGen only when real XCUITest app automation needs an Xcode project, in a
  separate full-Xcode GUI job. Do not add Tuist or require Xcode for source installs.
- Publish contributor commands for bootstrap, build, lint, format-check, individual
  suites and packaging checks. Measure idle CPU, wakeups and memory with features
  disabled and enabled; distinguish required shared services from leaked work.

## Documentation consolidation · implemented 2026-10-15

Root documentation now consists of `README.md`, `LICENSE` and `AGENTS.md`.
Use the [documentation index](README.md) for the moved guides:

- [Usage and defaults](usage.md), [modules and source architecture](modules.md),
  and [host terminology](glossary.md).
- [Validation index and revision-bound evidence](validation/README.md), including
  host transactions, integrated core fixes and historical UI validation.
- [Release checklist](releases/checklist.md) and [unreleased notes](releases/1.0-notes-draft.md).
- [Archived UI requirements](archive/ui-ux-plan.md) and
  [animation research](archive/animation-research.md), with original limits retained.

This docs-only consolidation preserves evidence and vendor notices, updates inbound
references and checks local links and anchors. It adds no registration framework,
source architecture refactor or CI. Native/hardware acceptance and final release
gates remain open.

## Deferred scope

Keep clipboard JSON storage until profiling shows a need for SQLite. If justified,
use the existing `ClipboardPersistence` seam, with migration, crash durability,
clear/retention deletion and unload/quit veto tests; do not introduce a generic DB layer.
Wheel attribution, per-device mouse controls, cross-Space/full-screen restoration
and notch-overflow UI remain unsupported, outside this architecture work.

Sources: [SwiftPM targets](https://docs.swift.org/latest/documentation/packagedescription/target/) · [Swift Testing](https://github.com/swiftlang/swift-testing) · [SwiftLint](https://github.com/realm/SwiftLint) · [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) · [XCTest](https://developer.apple.com/documentation/xctest) · [XcodeGen](https://github.com/yonaskolb/XcodeGen).
