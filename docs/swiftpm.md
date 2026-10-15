# Clipboard policy package

Requires Apple Silicon and macOS 15+. The manifest declares Swift tools 6.0
(Xcode 16 generation); Swift **5 language mode** remains in use and the helper
selects `--build-system native`. Only Apple Swift 6.4 has been validated here,
including standalone CLT package builds/tests; Swift 6.0 is a declared minimum,
not a locally validated toolchain. The installed CLT's default macOS 27 SDK cannot compile
the app's existing SwiftUI `@State` declarations (`SwiftUIMacros` is missing), also
reproducible with a standalone SwiftUI typecheck unrelated to the package. This
environment failure is not a requirement for full Xcode or a change to app sources.
The same standalone SwiftUI typecheck succeeds with the installed macOS 26.5 SDK
selected through `SDKROOT`, but the full app then hits a SwiftUI type-check budget
failure in `MonitorLayoutMap`. Building an unmodified `dc96e9c` source snapshot
reproduced that same failure. Neither pre-existing CLT/SDK problem is changed here;
no SDK version is hardcoded into the build scripts.

`Package.swift` defines one static `ClipboardPolicy` product and one test target.
[ClipboardHistory.swift](../Sources/Features/Clipboard/Policy/ClipboardHistory.swift)
contains the existing capture, retention and archive policy. Native pasteboard/UI
integration stays in `ClipboardModule.swift`. There are no package dependencies,
resources, dynamic libraries or runtime plugin loading.

## Commands (repository root)

```bash
bash build.sh                    # release app, packaged and signed as before
bash test.sh                     # app, named policy tests, legacy and shell suites

# Named suites, without building or launching the app:
bash -c 'source Scripts/clipboard-package.sh; clipboard_package_test debug --filter ClipboardPolicyTests.ClipboardPolicyTests'
bash -c 'source Scripts/clipboard-package.sh; clipboard_package_test debug --filter ClipboardStorageTests'
bash -c 'source Scripts/clipboard-package.sh; clipboard_package_test debug --filter ClipboardArchiveTests'

# All policy suites, release configuration:
bash -c 'source Scripts/clipboard-package.sh; clipboard_package_test release'

# Force standalone CLT rather than the selected Xcode:
DEVELOPER_DIR=/Library/Developer/CommandLineTools bash -c \
  'source Scripts/clipboard-package.sh; clipboard_package_test debug'
```

Each test owns fake clipboard/persistence state or a unique temporary directory;
no policy test initializes AppKit, reads the system clipboard or changes device
settings. Existing legacy tests remain in place during incremental migration.

## Build contract

[Scripts/clipboard-package.sh](../Scripts/clipboard-package.sh) centralizes the
arm64/macOS 15 triple, configuration, warnings-as-errors and SwiftPM output lookup.
`build.sh` still builds a release app; no new app configuration environment API is
introduced. Debug/release package outputs remain separate under `build/swiftpm`.

The native engine is selected explicitly: Swift 6.4 defaults to SwiftBuild, whose
output layout differs. Native is deprecated in 6.4, so future toolchain upgrades
must recheck this contract. `swift build --show-bin-path` supplies the actual output
directory; the helper verifies `Modules/ClipboardPolicy.swiftmodule` exists (file
or directory) and `libClipboardPolicy.a` is present. Manual app and legacy test
compilation import that module and link that archive, never compile its sources.
SwiftPM is the sole build owner of those sources; normal per-configuration builds
are intentional. C linking uses the three explicit owned objects, not a glob.

Standalone CLT 6.4's native engine fails to discover its Testing developer framework.
The test helper adds the selected CLT framework, macro-plugin and runtime search
paths only for `swift test`. Full Xcode discovery works without that workaround.
Production compilation/linking never receives these test paths or links Testing.

Bundling, notices, revision/source-install metadata, signing verification and
replacement rollback remain in `build.sh`. Installer freshness remains revision
based; no digest system or installer behavior changes are part of this extraction.
`Tests/build.sh` uses process fixtures to check package failure/missing outputs,
rollback, stale-object exclusion and absence of duplicate policy source inputs.

## Validation recorded for this extraction

On 2026-10-15, Apple Swift 6.4:

- Standalone CLT: clean release archive; clean/debug and release Swift Testing
  suites; incremental repeat debug suites — all 10 tests in 3 suites passed.
- Selected Xcode: `MAC_UTILS_SIGNING_IDENTITY=- bash test.sh` passed, including the
  same named tests, 4,220 existing isolated checks and shell installer/build tests.
- Actual arm64 signed bundle: complete notices, no dynamic ClipboardPolicy/Testing
  dependency, and signature/plist/notices retained after relocation, without launch.

These are build/test checks, not native device acceptance or permission validation.

## Main integration · 2026-10-15

Reviewed CLEAN source `f5094a8359b98f9e108ff91897ada049cdded0b8` integrated without
conflicts as `35fc4df82bcafe3923d4e53586becae0d37487d2`, preserving the current
pinned tooling and agent instructions. Selected tools: Xcode 27.0, Apple Swift 6.4,
SDK 27.0 on macOS 26.6.2 arm64; this is not a new standalone-CLT app-build result.

The single integrated `bash test.sh` run passed: **4,220 legacy isolated checks**,
**10 Swift Testing tests in three suites**, **13 mocked installer scenarios**,
expanded package/build rollback and link-ownership fixtures, and real/relocated
signed-bundle notice/dependency checks. Log: `build/swiftpm-integration.log` (ignored
local output). Release policy compilation and debug policy tests both ran; the
legacy runner links the release archive. SwiftPM emits a known native-engine
deprecation warning; future toolchain upgrades must revisit that contract.

Lint and format-check passed across **39 files**, including the moved policy, both
new test files and manifest; offline tooling regressions also passed. Source/built
plist lint, strict Apple Development signature and metadata checks passed: the
bundle embeds the integration revision above, version `0.4`, build `4`, arm64/macOS 15+.
All ten shell files passed `bash -n`; 93 local links/anchors across the five
integration documents and `git diff --check` passed. README was unchanged.
No real app launch/quit/install, live clipboard/preference/device mutation, version bump
or publication was performed. The separate CLT compatibility work is not integrated.
An evidence-only commit does not claim a final artifact at its own revision.
