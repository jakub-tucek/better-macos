# Development roadmap

Proposed work, based on `2620a32` (2026-10-15). None of the architecture or tooling
changes below are implemented by this document. Current behavior lives in
[MODULES.md](MODULES.md); acceptance and failures live in [VALIDATION.md](VALIDATION.md).
Keep the concise README and its install command. This plan promises no release date or tag.

## Priorities

| Priority | Work | Done when |
| --- | --- | --- |
| 0 | Finish release safety | Core fixes and watchdog/corrupt-journal regressions are reviewed and integrated through `dc96e9c`; complete native acceptance and record remaining hardware gaps at the tested revision. |
| 1 | Documentation and developer baseline | Agree on compiler/tool versions, contributor commands, lint/format checks and the documentation map below. Verify links and script references. |
| 2 | One SwiftPM slice and source organization | Extract one existing policy/backend boundary with tests; preserve app/helper behavior, CLT source installation and signed-bundle packaging. Move files in reviewable batches. |
| 3 | Built-in feature registration | Register multiple different features through a small host interface without changing persisted IDs, shared ownership or drain/veto behavior. |
| 4 | Test migration and CI | Run named isolated suites and shell/process regressions as PR gates; prove clean and incremental builds agree. |
| 5 | Native UI automation, if needed | Add a separate full-Xcode GUI job only for acceptance gaps that require app-driving tests. |
| Later | Measured performance/storage work | Compare idle resource baselines; consider SQLite only if clipboard measurements justify migration. |

Priority 0 remains open for native/physical acceptance and final release gates.
Display-recovery ownership, setup awake-assertion removal, watchdog authorization
and corrupt-journal preservation fixes are independently reviewed CLEAN and integrated. Use
[release evidence](RELEASE-CHECKLIST.md#current-evidence) and
[UI acceptance](UI-REPLACEMENT-VALIDATION.md), not test counts, to close these gates.

## Build and source boundaries

- Introduce **one local Swift package**, starting with an existing testable slice.
  Use a few meaningful targets for app composition, policy/backends and C boundaries;
  avoid a target per file or a package per feature. Reuse existing backend seams.
- Keep `build.sh` as the app-bundling entry point: plist/revision metadata, resources,
  complete licenses, signing verification and replacement rollback remain its job.
  Preserve the Apple Silicon/macOS 15+ CLT source-install path without full Xcode.
- Put C integration behind explicit C targets for MouseHID and vendored payloads;
  keep `Vendor/` contents and notices unchanged during this refactor.
- Move toward this layout without treating directory names as package boundaries:

```text
Sources/
  App/          # entry points, composition, setup and native host integration
  Core/         # host transactions, recovery/readiness and shared policy
  Features/     # Displays/, Audio/, Bluetooth/, Clipboard/, Mouse/, ...
  SharedUI/     # Settings shell, widgets and shared controls
MouseHID/       # C boundary, exposed through a package target
Vendor/        # existing pinned sources and notices
Tests/         # named suites plus shell/process fixtures
docs/          # current guides and revision-labelled evidence
```

Verify resources and helper/watchdog launch from the **installed, relocated bundle**.
Record source revision, SDK/compiler, dependency inputs, architecture and signing
mode for release reproducibility; do not claim byte-identical output across SDKs.

## Reusable modules: static registration first

- Define explicit **built-in registration** for identity, settings/navigation and
  host wiring. Preserve `AppModule` persisted IDs and existing preferences.
- Keep feature-specific operations behind existing interfaces. Preserve asynchronous
  drains, cleanup failure/retry and unload/quit vetoes; `HostTransactions` retains
  action-admission and termination authority.
- Keep one Audio owner shared with Bluetooth and shared Displays recovery reachable
  when individual display features are disabled. Registration must not duplicate them.
- Prove the interface with different lifecycles, for example Keep awake, Clipboard
  and Displays, before extracting more abstractions. Avoid universal `start/stop`
  adapters and a generic event bus. Test disabled-feature teardown and shared dependencies.
- Aim for reusable **build-time packages** after that proof. External runtime plugins,
  discovery, ABI compatibility and third-party code loading stay outside this plan.

## Tooling, tests and CI

- Document a tested compiler/SDK baseline. Today's scripts use Swift **5 language
  mode**; that differs from a Swift **6 toolchain**. Swift Testing ships with Swift 6 /
  Xcode 16: adopt it only after verifying the chosen CLT toolchain supports it.
- Pin development-only SwiftLint and SwiftFormat CLI versions with a version-checked
  bootstrap and `.editorconfig`. Start with a small high-signal ruleset; exclude
  vendor, build and generated files. Review any legacy baseline. CI checks must not
  mutate files; keep formatter rewrites separate from architecture changes.
- Replace the monolithic test runner incrementally with named independent suites
  using Swift Testing where supported. Keep XCTest for UI/performance tests.
  Use `@MainActor` for AppKit tests, isolated preferences/temp directories and fake
  clocks; serialize unavoidable shared state rather than racing global fixtures.
- Keep shell packaging/installer tests and watchdog subprocess tests as distinct
  suites. Keep live OS/hardware mutation opt-in and outside default unit checks.
- Replace `test.sh`'s `build/objects/*.o` link input with explicit target outputs or
  invocation-owned object lists; add a stale-object regression and clean-build check.
- On macOS arm64 CI, assert architecture and toolchain before lint, format-check,
  build, unit/process tests and packaging/installer PR gates. Select an available
  runner rather than assuming a hosted label implies Apple Silicon.
- Add XcodeGen only when real XCUITest app automation needs an Xcode project, in a
  separate full-Xcode GUI job. Do not add Tuist or require Xcode for source installs.
- Publish contributor commands for bootstrap, build, lint, format-check, individual
  suites and packaging checks. Measure idle CPU, wakeups and memory with features
  disabled and enabled; distinguish required shared services from leaked work.

## Documentation cleanup, after active validation settles

Keep root `README.md`, `LICENSE` and a future concise `AGENTS.md` for commands and
safety rules. Move guides in a docs-only change, linking the module guide from README.
These are candidate destinations, not moves made here:

| Existing files | Proposed home / treatment |
| --- | --- |
| `MODULES.md`, `GLOSSARY.md`, `ROADMAP.md` | `docs/modules.md`, `docs/glossary.md`, canonical `docs/roadmap.md`; retain a root glossary if instructions require it. |
| `HOST-TRANSACTIONS-VALIDATION.md`, source-map architecture sections | `docs/architecture/` guide; retain revision-bound host evidence under validation. |
| `VALIDATION.md`, `AWAKE-VALIDATION.md`, `WINDOW-POSITIONS-VALIDATION.md`, other `*-VALIDATION.md` | `docs/validation/` index and evidence; keep active core validation in place until its work finishes. |
| `UI-UX-PLAN.md`, `ANIMATION-RESEARCH.md`, superseded UI validation | `docs/archive/` with revision/status labels after checking for still-open acceptance work. |
| `RELEASE-CHECKLIST.md`, `RELEASE-NOTES-1.0-DRAFT.md`, `PACKAGING-VALIDATION.md` | `docs/releases/` checklist/notes, linked packaging evidence under validation. |

Retain failure evidence and historical results. Delete only proven redundant content;
check local Markdown links, anchors, scripts and instruction references after moves.
Leave vendor licenses and attribution intact.

## Deferred scope

Keep clipboard JSON storage until profiling shows a need for SQLite. If justified,
use the existing `ClipboardPersistence` seam, with migration, crash durability,
clear/retention deletion and unload/quit veto tests; do not introduce a generic DB layer.
Wheel attribution, per-device mouse controls, cross-Space/full-screen restoration
and notch-overflow UI remain unsupported, outside this architecture work.

Sources: [SwiftPM targets](https://docs.swift.org/latest/documentation/packagedescription/target/) · [Swift Testing](https://github.com/swiftlang/swift-testing) · [SwiftLint](https://github.com/realm/SwiftLint) · [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) · [XCTest](https://developer.apple.com/documentation/xctest) · [XcodeGen](https://github.com/yonaskolb/XcodeGen).
