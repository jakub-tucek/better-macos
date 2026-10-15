# Static built-in registration

This is a partial registration seam, not a runtime plugin system or a complete
feature lifecycle framework. All owners remain compiled into the app executable.

## Presentation catalog

[BuiltinFeatures.swift](../../Sources/App/BuiltinFeatures.swift) registers eleven `AppModule` identities and six widget
kinds. The catalog contains values only: titles, descriptions, dashboard
destinations, Settings membership/order and widget ownership/suggestion order.
Existing `AppModule`, `SettingsGroup` and `WidgetKind` properties are compatibility
facades over those definitions. SwiftUI view dispatch stays concrete; no view or
owner factory executes during metadata lookup.

Persisted raw IDs and preference keys are unchanged. Setup still applies features
in `AppModule.allCases` order, not Settings presentation order. Widget decoding
still stores a raw string so unknown entries survive round trips. Removing a
widget neither disables a feature nor clears its data.

## Registered choice preparation

[BuiltinChoicePreparations.swift](../../Sources/App/BuiltinChoicePreparations.swift) registers three distinct capabilities used by
the production `AppDelegate.setModule` path:

| Capability | Preparation | On refusal |
| --- | --- | --- |
| Keep awake disable | Deactivate the existing typed owner before commit | Reactivate the same owner and preserve enabled choice and retry state |
| Clipboard unload | Retry pending archive work without termination preparation | Preserve owner, pending work and capture/monitoring state |
| Shared Displays choice | Reject busy changes; asynchronously restore durable recovery before monitor/arrangement disable | Preserve choice and recovery ownership; release stopping marker for retry |

`ModuleChoiceFailure` separates per-feature failure detail from an optional banner.
Displays restoration already presents its own error, so preparation does not
replace that banner. One shared display adapter serves both persisted choices;
it does not construct a controller per feature.

The host still owns admission, preference commit, reconciliation and setup
staging. Both UI toggles and Setup Finish enter `setModule`, so they share real
preparation, including refusal and retry. A request admitted before asynchronous
cleanup may commit after admission closes. Its completion does not re-enter the
public guard; the stopping marker is removed exactly once before continuation.
Duplicate restoration callbacks cannot complete twice or clear a newer marker.

Display restoration remains `AppDelegate.restoreAll` → `runDisplayCommand` →
gesture drain → helper executor. Durable journals plus rollback state remain the
authority, not enabled features or dashboard counters. Recovery remains available
without watchdog readiness; supervised display mutations retain execution-time
authorization. Shared display recovery remains reachable when features are off.

Clipboard unload is not `prepareTermination`: refusal must not pause capture.
Successful unload stops runtime resources but leaves retention policy independent;
new history owners start capture paused. Keep awake preparation does not add a new
quit veto: its existing shutdown behavior is unchanged.

## Intentionally still host-composed

Owner construction/callback wiring and `updateModules` reconciliation remain
explicit and typed in `AppDelegate`. Audio remains one owner shared with Bluetooth,
with independent automatic-routing admission. Mouse, Menu bar, Spaces and their
restoration/drain behavior are unchanged. Setup preference staging, typed setup
application, draft cancellation and explicit Mouse Apply are unchanged.

`HostTransactions` alone controls action admission and quit approval. Its ordered
preparation, asynchronous drain, final checks, veto and reopening are not replaced
by a generic registration loop. The catalog does not infer dependencies from UI
groups, and the choice seam does not expose universal start/stop callbacks.

Further lifecycle extraction or reusable build-time packages require another
reviewed slice. The later mechanical [source organization](../modules.md#modules-not-a-plugin-system)
preserves these boundaries. Dynamic discovery/loading, event buses, ownership graph
engines and generalized setup schemas remain outside this registration seam.

## Regression surface

`Tests/UITests.swift` exercises catalog completeness, stable IDs, presentation
orders, unknown widget persistence and production UI/setup owner preparation with
injected assertion/archive failures and retries. `Tests/HostTransactionsTests.swift`
exercises both display choices through UI/setup, durable recovery without a ready
watchdog, accepted cleanup after admission closes, failure/retry and duplicate
completion protection. Existing host quit, execution authorization, corrupt-journal,
shared ownership, setup staging and native state/editor tests remain in place.

These isolated checks are not app-driving, TCC, physical-device or hardware
acceptance. The [module guide](../modules.md), [host glossary](../glossary.md),
[roadmap](../roadmap.md) and [validation index](../validation/README.md) describe
current ownership and remaining gates; historical evidence stays revision-bound.

### Implementation verification · 2026-10-15

Source: `4d9d50be0667b42e30eb2a4857ab3cdaf81d89bd`, after catalog commit
`e0fb93d`, based on `12ce15c`. On macOS 26.6.2 (`25G83`), Apple Silicon,
Xcode 27.0 (`27A266a`), Apple Swift 6.4 and SDK 27.0:

- Full `bash test.sh` passed at the committed source revision: **4,335 legacy
  isolated checks**, **10 Swift Testing tests in three suites**, **13 mocked
  installer scenarios**, build/link-ownership/failure fixtures and real/relocated
  signed-bundle notice, metadata and dependency checks. No app was launched.
- Strict configured certificate signature verification and source/built plist lint
  passed. The arm64 bundle embeds the source revision above, version `0.4`, build
  `4`, minimum macOS 15.0. This is not a final release artifact.
- Pinned SwiftLint/SwiftFormat passed across 44 files without rewrites; offline
  developer-tool regressions passed. Changed shell scripts passed `bash -n` and
  the source diff passed `git diff --check`.
- Production `StoredState` compiler fixtures passed with both standalone CLT 27
  and Xcode 27. A separate standalone-CLT warnings-as-errors typecheck of all app
  Swift sources, including both new registration files and the existing packaged
  policy import, passed. This is not another full CLT suite or minimum-toolchain
  acceptance claim.

Local logs are under
`/private/var/folders/01/q8lbfsh16d9bjtl88bpwtr840000gn/T/opencode/`:
`builtin-registration-4d9d50b-test.log`,
`builtin-registration-4d9d50b-lint.log`,
`builtin-registration-4d9d50b-format.log`,
`builtin-registration-clt-typecheck.log`, and
`builtin-registration-tools.log`. The empty typecheck log accompanies a successful
exit. An earlier precommit full run also passed the same counts; it is not the
revision-bound artifact record.

At this implementation record, independent review was still required before integration. No installation, real
app launch, permission grant, live clipboard capture/device mutation or system-preference
mutation was performed. Existing native/hardware acceptance gaps remain open.

## Main integration · 2026-10-15

All three source commits were independently reviewed CLEAN and integrated in order,
without conflicts, on top of the consolidated documentation paths:

| Reviewed source | Main commit |
| --- | --- |
| `e0fb93d` — inert presentation catalog | `613b757` |
| `4d9d50b` — typed choice preparation | `d16b178` |
| `113736a` — revision-bound source evidence | `66056f0` |

At **`66056f0486e6ad84cdf81e75568cd3ed84945a99`**, one integrated `bash test.sh`
run passed **4,335 legacy checks**, **10 Swift Testing tests in three suites**,
**13 mocked installer scenarios**, compiler/package/build fixtures and real/relocated
signed-bundle notices/dependency checks. The log is
`build/builtin-registration-integration.log`. It records HEAD, selected Xcode 27
compiler/SDK paths and versions (Swift 6.4 / SDK 27.0), arm64 architecture and bundle
metadata. `SDKROOT` was explicitly unset; no global tool selection changed.

Strict configured-certificate signature, source/built plist lint and metadata passed:
the arm64/macOS 15+ bundle embeds that revision, version `0.4`, build `4`, SDK 27.0.
Lint/format passed across **44 files**, including both new registration files;
offline tooling fixtures passed. Logs: `build/builtin-registration-integration-{lint,format,tools}.log`.
The standalone CLT 27 state compiler fixture passed separately, in addition to the
Xcode fixture in the suite. This is not another full CLT suite, minimum Swift 6.0
acceptance, hardware validation or a final artifact at the evidence commit.

SwiftPM retains sole ClipboardPolicy compilation ownership; app/tests import and
statically link its archive, with the same three explicit C objects. No root guides
were resurrected, README was unchanged, and the metadata/choice seam does not claim
owner factories or a complete feature lifecycle framework. No real app launch/quit,
install, live preferences/devices/permissions, version bump, push/tag or publication
was performed. Native/hardware and final release gates remain open.

All eleven shell files passed syntax checks; **198 local links and 32 fragments
across 25 tracked Markdown documents** and `git diff --check` passed.
