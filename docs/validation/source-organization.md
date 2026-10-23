# Mechanical source organization · 2026-10-15

Base: `76dd54268aeae78533e635f112099adcf69ee55a`.
Implementation: `9c8a94a0755d4caf1baca237c225b0a418ce6349`, isolated branch
`chore/source-organization`. This records implementation checks, not independent
review or integration approval. Native/hardware and final release gates remain open.

## Move map and byte preservation

All 31 root app Swift files moved with **100% byte identity**. There are no Swift
implementation/comment/import exceptions. `Package.swift` remains at the root;
its sole change is a compilation-ownership comment. Tests' Swift bytes, Clipboard
policy, `Vendor/`, `MouseHID/`, licenses and bundle resources remain unchanged.

Every filename in the first column was at the repository root; its new path is
the destination directory plus that filename:

| Files | Destination |
| --- | --- |
| main.swift, AppDelegate.swift, AppModules.swift, BuiltinFeatures.swift, BuiltinChoicePreparations.swift, SetupWizard.swift, SourceUpdates.swift, SafetyWatchdog.swift | `Sources/App/` |
| HostTransactions.swift, SystemControlLifecycle.swift, CommandRunner.swift | `Sources/Core/` |
| Dashboard.swift, UISurfaces.swift, StoredState.swift | `Sources/SharedUI/` |
| DisplayController.swift, DisplayTopology.swift, DisplayArrangementEditor.swift, DisplayRefreshGate.swift, ScreenEdges.swift | `Sources/Features/Displays/` |
| WindowPositions.swift, WindowPositionsView.swift | `Sources/Features/Windows/` |
| AnimationPreferences.swift, SpacesModule.swift | `Sources/Features/Animations/` |
| MouseModule.swift, MouseSystemBackend.swift | `Sources/Features/Mouse/` |
| AudioModule.swift | `Sources/Features/Audio/` |
| BluetoothModule.swift | `Sources/Features/Bluetooth/` |
| ClipboardModule.swift | `Sources/Features/Clipboard/` |
| KeepAwakeModule.swift | `Sources/Features/KeepAwake/` |
| MenuBarModule.swift | `Sources/Features/MenuBar/` |
| QuitGuard.swift | `Sources/Features/QuitGuard/` |

`Sources/Features/Clipboard/Policy/ClipboardHistory.swift` did not move. SwiftPM
package description still reports only `ClipboardPolicy` and `ClipboardPolicyTests`,
and exactly that one policy source. The narrow explicit target path already excludes
all other app sources; no broad parent target/exclude mask was introduced.

The original and moved bytes were compared directly using `git show` and filesystem
reads. Reproduce the comparison and print equal before/after SHA-256 digests:

```sh
python3 - <<'PY'
import hashlib, subprocess
base = '76dd54268aeae78533e635f112099adcf69ee55a'
moved = '9c8a94a0755d4caf1baca237c225b0a418ce6349'
changes = subprocess.check_output(
    ['git', 'diff', '--name-status', '-M100%', base, moved], text=True)
count = 0
for line in changes.splitlines():
    fields = line.split('\t')
    if fields[0] != 'R100':
        continue
    old, new = fields[1:]
    before = subprocess.check_output(['git', 'show', base + ':' + old])
    after = subprocess.check_output(['git', 'show', moved + ':' + new])
    assert before == after, (old, new)
    print(old, new, hashlib.sha256(before).hexdigest(), hashlib.sha256(after).hexdigest())
    count += 1
assert count == 31, count
PY
```

The app/legacy explicit input lists also compare exactly to the base after filename
substitution: same order, flags, vendor inputs, three C objects and policy archive;
the app uses `Sources/App/main.swift`, the legacy runner uses `Tests/main.swift`.
No shared manifest abstraction, lifecycle extraction, runtime plugin, CI change or
installation behavior change was added. Current source links were relocated;
historical revision-bound paths/results remain historical.

SwiftLint baseline JSON compares exactly after substituting its four file paths
with `Sources/Features/Windows/WindowPositions.swift`. Rule IDs, four line/character
locations and all other exception data are unchanged; neither tool's include/exclude
configuration changed. Tooling fixtures now prove App/Core/SharedUI/native feature
and policy paths are linted/formatted. Compiler fixtures now check source existence,
root-source rejection, distinct entry points, and missing-source failure with an
existing bundle/stale objects, in addition to original package/link/rollback checks.

## Revision-bound checks

Environment: macOS 26.6.2 (`25G83`), arm64, selected Xcode 27.0 (`27A266a`),
Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), SDK 27.0, Swift 5 language mode.
`BETTER_MACOS_SIGNING_IDENTITY=-` selected ad-hoc signing; global tool selection and
local signing configuration were not changed.

At the implementation revision, from this new worktree with no previous app,
objects or SwiftPM outputs:

- `bash test.sh` passed: **4,335 legacy isolated checks**, **10 Swift Testing tests
  in three suites**, **13 mocked installer scenarios**, production state compiler
  fixture, package/build/link-ownership/rollback/source-absence fixtures, and real
  plus relocated bundle checks. The policy release archive and debug tests both
  compiled cleanly. The known native-engine deprecation warning remains unchanged.
- Bootstrap verified pinned developer tools. Lint passed with zero violations
  across **44 files**; format-check required no changes across **44 files**.
  Expanded offline tooling fixtures passed, including organized source roots.
- Standalone CLT 27's production `StoredState` compiler fixture passed. A separate
  warnings-as-errors CLT/SDK 27 production typecheck passed using exactly 31 moved
  app and four vendor Swift files and the existing policy module import. This is
  not another full standalone-CLT suite or proof of the declared minimum toolchain.
- Strict signature verification, arm64 architecture, macOS 15.0 deployment/SDK 27.0
  metadata and embedded implementation revision matched. Packaging tests compared
  complete project/vendor/upstream notices before and after relocation, preserved
  plist bytes/signature and rejected dynamic ClipboardPolicy/Testing dependencies;
  neither original nor relocated app was launched.
- An incremental `bash build.sh` repeat passed with the existing policy archive
  (SwiftPM release build: 0.12 seconds), followed by all ten debug policy tests
  (incremental build: 0.12 seconds) and repeat real/relocated packaging checks.
  The manually compiled app was rebuilt/signed successfully; no compiler input
  was replaced by a stale root source or object glob.
- Shell syntax, byte/input/baseline/package-ownership assertions and local Markdown
  checks passed: **202 local destinations and 33 fragments** across tracked Markdown
  plus this evidence file. `git diff --check` passed. Historical validation results
  were not rewritten.

Local logs are under
`/private/var/folders/01/q8lbfsh16d9bjtl88bpwtr840000gn/T/opencode/`:
`source-organization-9c8a94a-test.log`, `source-organization-bootstrap.log`,
`source-organization-lint.log`, `source-organization-format.log`,
`source-organization-tools.log`, `source-organization-clt-typecheck.log`, and
`source-organization-incremental.log`.

At this implementation record, independent review was still required before integration. No real app launch/quit,
install, TCC change, live clipboard/device/preference mutation, version bump,
push/tag or publication was performed. Default fixtures remain isolated. The
evidence-only commit does not claim a final artifact at its own revision.

## Main integration · 2026-10-15

Independently reviewed CLEAN commits `9c8a94a` and `49b6398` integrated as `28e152b`
and **`480e957b66df14f870ce43a96fde1a0ba78ec9ba`** on main `c4e0af0`. AGENTS/roadmap
conflicts were resolved by retaining configured CI, unverified hosted execution and
unconfigured branch protection while recording completed mechanical source moves.
Broader lifecycle/factory work remains partial; directories are not new package
boundaries. The separate KeepAwake adapter work was not integrated.

Actual checks at this integrated revision:

- Direct byte comparisons against prior main `c4e0af0` passed for **all 31 moves**;
  each old path is absent. Whole `build.sh`/`test.sh` files compare exactly after
  substituting moved paths, preserving compiler flags/order, distinct app/runner
  entry points, one policy module/archive and three explicit C objects.
- The four SwiftLint exceptions compare exactly after only their file-path
  substitutions. Policy, Swift test bodies, vendor/C sources, licenses, plist,
  workflow calls and CI helpers are unchanged. `Package.swift` adds only an ownership
  comment; it does not add a target or compile the app via SwiftPM.
- One full `bash test.sh` passed: **4,335 legacy checks**, **10 Swift Testing tests
  in three suites**, **13 mocked installer scenarios**, production state compiler,
  expanded source-absence/package/link/rollback fixtures and real/relocated bundle
  notice/signature/dependency checks. Log: `build/source-organization-integration.log`.
  It records HEAD, selected Xcode 27 / Swift 6.4 / SDK 27.0 paths/version, arm64 and
  bundle metadata, with command-scoped tools and explicitly unset `SDKROOT`.
- Strict configured-certificate signature, plist lint and metadata passed: the
  arm64/macOS 15+ bundle embeds the tested revision, version `0.4`, build `4`, SDK 27.0.
- Lint and format-check passed across **44 files**; expanded offline tooling fixtures
  checked organized app/core/UI/native feature/policy roots. Offline CI whitespace
  fixtures and actionlint 1.7.12 passed, retaining only the documented `xcode-27`
  preview-label exception with ShellCheck disabled. Logs:
  `build/source-organization-integration-{lint,format,tools,ci}.log`.
- Source blob/input/baseline assertions are recorded with matching digests in
  `build/source-organization-integration-paths.log`. README remains unchanged.
- The actual SwiftPM package description confirms only policy and named test targets,
  with one policy source. All explicit compiler paths and unchanged workflow commands
  exist; YAML/run-block syntax, all **13 shell files**, **215 local links and 36
  fragments across 27 Markdown documents**, and `git diff --check` passed.

Historical failures and earlier counts remain revision-bound. No new full CLT,
minimum-toolchain, hosted CI, physical hardware or final release acceptance is
claimed. No real app launch/quit/install, live preferences/devices/permissions,
version bump, push/tag or publication was performed; default fixtures are isolated.
This evidence-only commit does not embed its own revision in the tested bundle.
