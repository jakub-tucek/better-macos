# Working in Fix macOS
## Read by task

- For feature ownership, shared dependencies, UI entry points or cleanup, read
  [module guide](docs/modules.md). Built-in features are compiled into one app, not runtime plugins.
- For developer commands and pinned lint/format tools, read [docs/development.md](docs/development.md),
  including [tested CLT state compatibility](docs/validation/clt-compatibility.md). For Clipboard policy
  ownership and named suites, read [docs/swiftpm.md](docs/swiftpm.md). For metadata and
  typed choice preparation, read [built-in registration](docs/architecture/builtin-registration.md).
  For the extracted Keep awake owner/presentation seam, read [owned feature](docs/architecture/keep-awake-feature.md).
  For configured CI and unverified hosted execution, read [CI guidance](docs/ci.md).
  Broader lifecycle extraction remains proposed in [the roadmap](docs/roadmap.md).
- For testing or release claims, read [validation](docs/validation/README.md) and its linked
  revision-bound evidence. Preserve historical failures and hardware acceptance gaps.
- For host coordination terminology, use [the glossary](docs/glossary.md).

## Current commands and layout

Run from the repository root on Apple Silicon macOS with Command Line Tools:

```sh
bash scripts/dev bootstrap    # verified, repository-local pinned developer tools
bash scripts/dev lint         # non-mutating SwiftLint checks
bash scripts/dev format-check # non-mutating SwiftFormat checks
bash build.sh       # compile, bundle and verify signing; does not launch the app
bash test.sh        # build, packaging/build fixtures, Swift Testing, legacy/installer tests
git diff --check
```

The scripts target arm64/macOS 15+ in Swift 5 language mode. First-party app Swift
lives under `Sources/`: `App/`, `Core/`, `Features/<owner>/` and `SharedUI/`; see the module
guide for ownership. `Sources/App/main.swift` is the app/helper entry point;
`Tests/main.swift` is the isolated runner. `MouseHID/` is the C boundary.
SwiftPM alone compiles `Sources/Features/Clipboard/Policy`; app/legacy tests import
and statically link `ClipboardPolicy`, never compile its sources manually. Update
explicit inputs in build/test scripts only for sources outside that package.
Use `StoredState` for existing SwiftUI local state; preserve its public-wrapper semantics.
`build.sh` produces `build/Fix macOS.app`; signing uses `MAC_UTILS_SIGNING_IDENTITY`
or local Git `macutils.signingIdentity`, otherwise ad-hoc. Preserve bundle notices,
strict signature verification and staged replacement/rollback.

## Safety contracts

- `HostTransactions` owns host admission and quit approval. Route actions through
  host guards, including non-UI callers; disabled controls alone are not admission.
  Preserve asynchronous drain, final cleanup checks, veto and canceled-quit reopening.
- Feature owners retain restoration responsibility. Preserve pending recovery and
  retry state after failures, including disabled-feature startup/teardown paths.
  Keep shared Audio/Bluetooth ownership and shared display recovery reachable.
- Input activation requires watchdog/readiness checks. Display disabling requires a ready watchdog;
  restore/recovery must remain available without one. Drain active gestures and cancel queued
  gestures before display changes/shutdown. Preserve last-usable-display and identity safeguards.
- Keep persisted `AppModule` raw IDs, preference keys and existing user choices stable.
  Widget removal is not feature disable or data deletion; Clipboard capture,
  retention and cleanup are distinct choices, with unload/quit vetoes on pending work.
- Setup edits are staged until Finish; cancellation discards drafts, not macOS grants.
  Apply through the host, report per-feature outcomes and preserve explicit Mouse Apply.
- `Vendor/strafe` is pinned and locally patched: preserve gesture cancellation/drain
  and injected test phases. Consult [UPSTREAM.txt](Vendor/strafe/UPSTREAM.txt) and keep
  complete [vendor notices](Vendor/strafe/LICENSE) and project license in built bundles.

## Validation and collaboration

Use isolated preferences/temp files and injected backends; default tests must not
mutate live displays, input, audio, clipboard or system preferences. App launch,
installation and live hardware checks require explicit authorization. Isolated checks
are not native/hardware acceptance. Core fixes are reviewed, integrated and validated;
see [release evidence](docs/releases/checklist.md#current-evidence) for revisions and open gates.

User preference: Astra for planning; Sol for background implementation and independent
review when appropriate. Delegate only when authorized; keep reviewer ownership
independent of implementation. Keep parallel work isolated in worktrees and scoped
commits; leave unrelated changes intact.
