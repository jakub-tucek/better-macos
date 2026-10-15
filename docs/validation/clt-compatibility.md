# Standalone CLT SwiftUI compatibility · 2026-10-15

Implementation/test revision: `a90cf68f8f37c16b8f52c51bc1c8e26a4586d13e`,
based on `7f0f0ff`. Host: Apple Silicon, macOS 26.6.2 (`25G83`). This is
build/isolated-test evidence, not an installation or hardware acceptance record.

## Failure and bounded fix

The earlier development baseline `b7a67ab` failed on standalone CLT 27 at
`WindowPositionsView.swift`: `SwiftUIMacros.StateMacro` plugin not found. A minimal
SwiftUI view containing `@State private var text = ""` reproduces it; the unchanged
app also failed during diagnosis. Xcode passed the same compiler/language flags.

CLT and Xcode have byte-identical `swift-frontend` executables. SDK 27 exports
both a `State()` macro and the public `State<Value>` property wrapper; the annotation
selects the macro. Only Xcode's macOS platform directory supplies
`libSwiftUIMacros.dylib`. Adding CLT's existing plugin directory does not help.
Borrowing Xcode's plugin does work but is not a CLT-only solution. Swift 6 language
mode, explicit `@State<String>`, and a same-name `State` typealias do not fix it.

`StoredState.swift` defines a distinct internal alias of `SwiftUI.State<Value>`.
Only the state annotation names changed in the five existing view files; stored
property names, access, bindings and explicit `_draft = State(initialValue:)`
initializers remain unchanged. Both build scripts explicitly include the alias.
No plugin copying, SDK fallback, Xcode discovery, language migration or new runtime
state abstraction is introduced.

This intentionally retains the pre-27 public property-wrapper semantics, **not all
new macro semantics**. Inspection of the SDK 27 expansion shows synthesized peers,
accessors and thunk-backed storage rather than ordinary wrapper synthesis. The
alias keeps legacy value initialization and graph-managed `DynamicProperty`
storage. Current initial values are local values/drafts, not side-effecting OS
operations; no caller depends on macro-only behavior. Future macro features or
observable-reference initializer semantics require a separate review.

## Exact-revision checks

Both runs started without `build/`, using command-scoped `DEVELOPER_DIR` and
`MAC_UTILS_SIGNING_IDENTITY=- bash test.sh`. No global `xcode-select` change or
`SDKROOT` override was used.

| Developer tools | Swift / SDK | Result |
| --- | --- | --- |
| Standalone CLT `27.0.0.0.1788430756` | Swift 6.4 (`swiftlang-6.4.0.34.1`), SDK 27.0 | PASS |
| Xcode 27.0 (`27A266a`) | Same Swift version, SDK 27.0 | PASS |

Each run passed:

- Production-alias compiler fixture with warnings as errors, Swift 5 language mode,
  arm64/macOS 15 target, inferred/optional state, bindings and explicit storage init.
- Clean optimized app build, strict ad-hoc signature verification and exact complete
  project/vendor notice comparisons; bundle revision matches `a90cf68`.
- Four build fixture groups, **4,226 isolated checks**, and thirteen mocked installer
  scenarios. Binary metadata: arm64, minimum macOS 15.0, SDK 27.0.
- Pinned SwiftLint/SwiftFormat checks (39 first-party Swift files, no violations or
  formatting rewrites). Tools reused locally; no downloads. Shell syntax and
  `git diff --check` also passed.

Six new native checks mount an unpresented owned `NSHostingView`: value/nil/explicit
draft initialization, projected writes, redraw invalidation, persistence across
same-identity initializer changes, optional clearing, and reset on identity change.
Existing production duration-editor tests also pass for focused drafts, invalid
edits, focus loss, removal/reopening, staged setup navigation and Cancel. Existing
host/setup tests retain injected backends and isolated preferences.

Local, ignored logs in the implementation worktree:
`evidence/a90cf68-{clt,xcode}-clean-suite.log`,
`evidence/a90cf68-{clt,xcode}-{lint,format}.log`.
The initial CLT suite attempt hit the command runner's 120-second timeout; it is
not counted as a pass. Subsequent complete runs used a 600-second allowance.

## Limits and installer follow-up

No real app launch/quit, installer run, live clipboard/device access, permission
request or system-preference mutation was performed. Native fixtures use hidden
owned windows, isolated preference domains and fake backends. There is no claim
of macOS 15 runtime acceptance, older CLT support, relocated installed-bundle
acceptance, final release artifact validation or independent review.
This branch predates the parallel ClipboardPolicy SwiftPM integration. Preserve
both its package inputs and these explicit compatibility/test inputs when merging;
rerun the combined suites before claiming integrated-main acceptance.

The installer is unchanged. Its streamed standalone entry point cannot compile
the repository's actual alias before the initial clone/fetch without separately
retrieving source or duplicating the declaration. A plain `@State` preflight would
falsely reject this fixed CLT path. A reliable pre-fetch source-aware preflight is
deferred rather than adding that false gate. Existing mocked build-failure tests
still prove the previous app remains installed and no quit occurs after build
failure; they do not prove no preceding Git/Homebrew mutation. Installation still
checks only compiler presence before those operations.

The available CLT SDK 26.5 passes the minimal original fixture but the unchanged
full app encountered a type-checking timeout at `Dashboard.swift:364`; selecting
an older SDK silently is neither implemented nor considered validated.
