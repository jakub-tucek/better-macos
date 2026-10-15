# Development

## Host and compiler

Use Apple Silicon macOS; the app targets **arm64 / macOS 15+**. That deployment
target is not a claim that every compiler/SDK combination builds the app.

Combined SwiftPM/state-compatibility source tested on 2026-10-15 at `dff0491`
on macOS 26.6.2 arm64 (earlier source evidence at `a90cf68` is retained separately):

| Selected developer tools | Compiler / SDK | Result |
| --- | --- | --- |
| Xcode 27.0 (`27A266a`) | Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), macOS SDK 27.0 | Clean combined build/full suite: 4,226 legacy checks + 10 policy tests/3 suites + 13 installer scenarios; lint/format and tooling fixtures pass. |
| Standalone CLT 27.0 (`27.0.0.0.1788430756`) | Same compiler version and SDK | Same clean combined checks pass, without Xcode plugin borrowing or SDK fallback. |

`build.sh` and `test.sh` use **Swift 5 language mode** (`-swift-version 5`), not a
Swift 5 compiler. Swift 6 strict concurrency is not adopted. The [Clipboard policy
package](swiftpm.md) now uses Swift Testing and declares Swift tools 6.0; only Swift
6.4 has been validated here, not the declared 6.0 minimum.
The earlier `b7a67ab` CLT build failed because SDK 27's `@State` resolves to a
`SwiftUIMacros.StateMacro` plugin absent from standalone CLT. The app now explicitly
uses the public property-wrapper type via `StoredState`; that build gap is resolved
for the tested tools. See [compatibility evidence](validation/clt-compatibility.md)
for state-lifecycle checks and limits. Source installation still does not require
lint/format tools or full Xcode. These checks did not run a real installer and do
not establish an older CLT minimum.

Inspect/select tools per command, without changing global `xcode-select` state:

```sh
xcrun swiftc --version
xcrun --sdk macosx --show-sdk-version
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/dev build
```

## Commands

From the repository root (the wrapper also works from another directory):

```sh
bash scripts/dev bootstrap       # download verified, pinned development tools
bash scripts/dev lint            # SwiftLint, warnings fail; no fixes or cache
bash scripts/dev format-check    # SwiftFormat --lint; no rewrites or cache
bash scripts/dev build           # existing build.sh; bootstrap is NOT required
bash Tests/swiftui-compatibility.sh # compile production state alias with selected tools
bash scripts/dev-tools-test.sh   # offline tooling regressions after bootstrap
bash Tests/packaging.sh          # inspect notices/signature after a successful build
```

Build output: `build/Fix macOS.app`. Building signs the local bundle; it does not
install or launch it. Existing signing configuration still applies; use
`MAC_UTILS_SIGNING_IDENTITY=- bash scripts/dev build` for explicit ad-hoc signing.

The full regression entry point is `bash test.sh` (build, packaging/build fixtures,
ten Swift Testing policy tests in three suites, legacy isolated runner and installer
fixtures). [Named policy-suite commands and compilation ownership](swiftpm.md#commands-repository-root)
are available separately; other feature suites still use the legacy runner.
See [validation](validation/README.md) and
[release checks](releases/checklist.md) for safety/hardware acceptance; a build or
lint pass does not replace them. Tooling verification does not run the full suite
or manipulate live preferences, applications or devices. No CI is added here.

## Pinned development tools

[`scripts/dev-tools.env`](../scripts/dev-tools.env) pins
[SwiftLint 0.65.1](https://github.com/realm/SwiftLint/releases/tag/0.65.1) and
[SwiftFormat 0.63.1](https://github.com/nicklockwood/SwiftFormat/releases/tag/0.63.1).
These are upstream macOS release archives, not Homebrew packages. Bootstrap uses
system `curl`, `shasum` and `unzip`, checks SHA-256 **before extraction/execution**,
then checks the binary version. Downloads/installations stay in ignored
`build/dev-tools/`; no sudo, global package updates or PATH installation. Versions
are checked again on every lint/format-check and bootstrap reuse. Existing wrong
versions fail rather than falling back to global tools. Run one bootstrap at a time.

To repair a missing/corrupt local tool, remove only its indicated version directory
under `build/dev-tools/` and bootstrap again. Cleaning `build/` also removes tools.
Network/checksum errors fail closed and remove invocation-owned staging files.
Checks themselves never bootstrap or access the network.

For upgrades, review both upstream release notes, replace version/URL/SHA together,
and verify the hash against the release asset's `digest` in the official GitHub API:
`https://api.github.com/repos/realm/SwiftLint/releases/tags/0.65.1` and
`https://api.github.com/repos/nicklockwood/SwiftFormat/releases/tags/0.63.1`.
Re-run bootstrap, checks and tooling regressions on the selected compiler/SDK.
Hashes authenticate pinned upstream bytes, not a separate publisher signature.

## Deliberately narrow baseline

- `.editorconfig`: UTF-8, LF, final newline, four-space code indentation; two spaces
  for data/Markdown. Markdown hard-break whitespace is preserved.
- SwiftLint: duplicate imports, forced casts/tries, empty fatal-error messages and
  unused optional bindings only. All five rules are SourceKit-free; the wrapper
  disables SourceKit loading so these checks also run with standalone CLT. The
  tooling regression rejects configured rules requiring SourceKit.
- `.swiftlint-baseline.json` records exactly four existing `AXValue` forced casts
  in `WindowPositions.swift` (baseline lines 338 and 401). Each is preceded by a
  `CFGetTypeID(...) == AXValueGetTypeID()` guard. This narrowly accepts existing
  bridging code, not arbitrary new forced casts. Review exceptions when touching
  that code; do not blanket-regenerate the baseline to make checks pass.
- SwiftFormat checks trailing spaces, consecutive blank lines and final newline
  only. First-party Swift files pass without formatting rewrites. No full-style
  baseline, mass formatting, naming/length rules or automatic rewrite command.
- Both tools exclude `Vendor/`, `build/`, `.build/`, `.swiftpm/`, `.git/`,
  `worktrees/`, `.worktrees/`, `generated/` and `Generated/`. Keep worktrees outside
  the repo or in those excluded directories; add any future generated roots to
  both configurations. First-party app code, `Sources/` and `Tests/` remain checked.

Keep style expansion and formatter rewrites separate from architecture changes.
Project context: [modules](modules.md), [glossary](glossary.md),
[roadmap](roadmap.md).

## Main integration verification · 2026-10-15

At `228f367`, bootstrap verified both pinned archive hashes and tool versions;
lint passed with zero violations across 36 files, format-check required no changes
across 36 files, and offline tooling regressions passed. `Tests/packaging.sh` passed
against the existing signed `dc96e9c` bundle, not a fresh tooling-revision build.
Production sources/build scripts are unchanged. No full feature suite, app build,
install/launch or live OS mutation was performed for this tooling integration;
the standalone-CLT build gap remained open at that revision. See the later
[combined compatibility record](validation/clt-compatibility.md#combined-main-integration)
for its resolution and current limits.
