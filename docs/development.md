# Development

## Host and compiler

Use Apple Silicon macOS; the app targets **arm64 / macOS 15+**. That deployment
target is not a claim that every compiler/SDK combination builds the app.

Tested on 2026-10-15 against source baseline `b7a67ab`:

| Selected developer tools | Compiler / SDK | Result |
| --- | --- | --- |
| Xcode 27.0 (`27A266a`) | Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), macOS SDK 27.0 | Build, lint and format-check pass on macOS 26.6.2 arm64. |
| Standalone CLT 27.0 (`27.0.0.0.1788430756`) | Same compiler version and SDK | Lint/format-check pass; app build fails: missing `SwiftUIMacros.StateMacro` plugin at `WindowPositionsView.swift`. |

`build.sh` and `test.sh` use **Swift 5 language mode** (`-swift-version 5`), not a
Swift 5 compiler. Swift 6 strict concurrency and Swift Testing are not adopted here.
The CLT-only source-install path remains independent of developer tools, but this
CLT 27.0 app-build failure is an open compatibility gap, not a successful install
test. No older CLT minimum is established by these checks.

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
bash scripts/dev-tools-test.sh   # offline tooling regressions after bootstrap
bash Tests/packaging.sh          # inspect notices/signature after a successful build
```

Build output: `build/Fix macOS.app`. Building signs the local bundle; it does not
install or launch it. Existing signing configuration still applies; use
`MAC_UTILS_SIGNING_IDENTITY=- bash scripts/dev build` for explicit ad-hoc signing.

The existing full regression entry point is `bash test.sh` (build, packaging/build
fixtures, isolated Swift runner, installer fixtures). Individual Swift suites are
not separate commands yet. See [validation](../VALIDATION.md) and
[release checks](../RELEASE-CHECKLIST.md) for safety/hardware acceptance; a build or
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
  only. All 36 first-party Swift files pass without source edits. No full-style
  baseline, mass formatting, naming/length rules or automatic rewrite command.
- Both tools exclude `Vendor/`, `build/`, `.build/`, `.swiftpm/`, `.git/`,
  `worktrees/`, `.worktrees/`, `generated/` and `Generated/`. Keep worktrees outside
  the repo or in those excluded directories; add any future generated roots to
  both configurations. First-party app code and `Tests/` remain checked.

Keep style expansion and formatter rewrites separate from architecture changes.
Project context: [modules](../MODULES.md), [glossary](../GLOSSARY.md),
[roadmap](../ROADMAP.md).

## Main integration verification · 2026-10-15

At `228f367`, bootstrap verified both pinned archive hashes and tool versions;
lint passed with zero violations across 36 files, format-check required no changes
across 36 files, and offline tooling regressions passed. `Tests/packaging.sh` passed
against the existing signed `dc96e9c` bundle, not a fresh tooling-revision build.
Production sources/build scripts are unchanged. No full feature suite, app build,
install/launch or live OS mutation was performed for this tooling integration;
the standalone-CLT build gap above remains open.
