# Saved Bluetooth targets and empty discovery · 2026-10-16

Base: `52ae53e`. This corrects popup guidance and adds observation diagnostics.
It does **not** fix the underlying radio/discovery problem or establish hardware
acceptance. No real helper, permission change or app relaunch was used.

The parent supplied independent **CLEAN** review of this visibility series; see
[main integration](#main-integration--2026-10-16). Earlier review-pending statements
below retain their historical revision scope.

Later integration of the reviewed native-coordinate fixture and read-only
Bluetooth observation boundary passed at `f0d8cf1`; see
[final combined evidence](../architecture/bluetooth-observation.md#final-integrated-evidence--f0d8cf1).
The failed `5feb438` main result below remains revision-bound historical evidence.

## Confirmed presentation defect

The reported popup displayed both “Choose targets” and “2 chosen devices
unavailable; targets are preserved.” The saved choices were still present.
`QuickWidget` tested whether any discovered device matched the saved choices,
then recommended choosing targets even when the saved set was nonempty.

The popup now asks to choose targets only when none are saved. With saved targets
but no matches it says:

> Saved targets unavailable. Check Bluetooth status and access in Sound & connections.

The retained-target count stays visible. Partial matches keep their actions and
missing count. Neither this copy nor an empty inventory asserts denied permission,
radio-off, deleted choices or removed macOS pairings.

## Discovery is not authorization evidence

In [blueutil 2.14.0](https://github.com/toy/blueutil/blob/60d8411fa3f9968ab6f05e198b486fe89961e18f/blueutil.m#L570-L609),
paired-device JSON serializes an empty/nil API result as `[]`; the paired command
returns success. The app accepts that JSON as successful empty discovery. Such a
result does not trigger the earlier observation-error correction.

Upstream [#85](https://github.com/toy/blueutil/issues/85) and
[#82](https://github.com/toy/blueutil/issues/82) report launch-context permission
affecting device visibility despite other working commands. Those reports do not
prove this user's current authorization or a Tahoe-specific bug. Two output bytes
alone do not establish the payload. The helper's discovery source may also depend
on its environment, which this change does not inspect or alter.

Saved IDs retain exact matching and persisted values. There is no address
normalization, experimental system-profiler fallback or new permission policy.
Formatting differences can matter with nonempty discovery; they cannot repair
an actual empty array.

## Privacy-safe state events

`BluetoothBackend` reports typed outcomes at existing read boundaries without
changing thrown errors or issuing extra commands. The Bluetooth owner publishes
`bluetooth/discovery_state_changed` through injected `Diagnostics` after worker
completion or a saved-choice/access-state change. It keeps only one previous
scalar key and suppresses identical states, including repeated failures.

Fields distinguish:

- `discovery_outcome`, `read_stage`, `command_outcome`, `decode_outcome`;
- `parsed_device_count` from the latest completed paired parse, or `unknown`;
- `inventory_device_count` and `matched_target_count` from the owner's currently
  published inventory, plus `saved_target_count`;
- last observed `radio_state` (`on`, `off`, `unknown`), `inventory_stale`, and
  current `parent_authorization`;
- `helper_authorization=unknown` and `helper_discovery_source=unknown`, explicitly
  independent of parent authorization and successful empty output.

Parsed and published inventory counts are separate: a later connection/routing
failure may leave the previously published inventory intact. `inventory_stale`
retains the existing observation-error meaning. Logs are observational, may be
dropped, and never authorize actions or alter UI state. They contain no device
IDs/names, executable paths, raw output or error payloads. Existing per-command
events still report coarse exit/timing results.

## Isolated checks

The production host/owner/CommandRunner fixture returns exact `[]` with radio `1`
and two saved targets, then mounts the actual popup row for native accessibility
inspection. Cases cover no saved targets, partial/full matches, unmatched
inventory, command/decode failures, recovery, unchanged-state deduplication and
sentinel identities/raw output absent from logs. Process-local AX materialization
is restored; no TCC grant is requested.

After normal test compilation, the focused host/native loop is:

```sh
build/isolated-tests --bluetooth-discovery-visibility-regressions
```

The separate permission-context runner also checks logged parent/helper separation
and power-command versus paired-decode evidence. Validation results are recorded
after frozen checks; no live functionality acceptance is implied.

### Negative control and path limitation

Temporarily restoring the original `QuickWidget` branch produced the exact native
assertion failure: “native popup shows preserved unavailable targets without
asking to choose them again.” Radio-on/empty-JSON target preservation had already
passed. The incorrect branch was then removed; it is not part of the fix.
Log: `build/discovery-visibility-copy-red.log` in the implementation worktree.

The initial combined run passed 4,765 legacy checks, 81 diagnostics, 114 instant
gesture-safety checks, 36 permission-context checks, 10 policy tests/3 suites and
13 installer scenarios. It precedes the final default-runner logger injection
and invalid-power-readback test. Those require the later frozen run.

Temp-path lint reported the four unchanged WindowPositions force-cast exceptions,
matching the already documented path-dependent baseline limitation. No baseline,
tooling configuration or CI file was changed. Final lint/tooling checks must use
the normal-path validation worktree; temp-path failure is not counted as a pass.

### Frozen validation · `5fcc364`

Clean detached normal-path worktree at
`5fcc36405e404cacfff4fe6641b74ff7a743f513`, command-scoped standalone CLT and
explicit ad-hoc signing:

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools BETTER_MACOS_SIGNING_IDENTITY=- bash test.sh
bash scripts/dev lint
bash scripts/dev format-check
bash scripts/dev-tools-test.sh
bash scripts/ci-whitespace-test.sh
git diff --check
```

Results:

- **4,765 legacy isolated checks**, **81 diagnostics**, **114 instant gesture
  safety checks**, **39 focused permission-context checks**, **10 policy tests in
  3 suites**, and **13 mocked installer scenarios** passed.
- App build, strict ad-hoc signature, complete notices, relocated-bundle and
  build-input/failure fixtures passed. Embedded bundle revision is exactly
  `5fcc36405e404cacfff4fe6641b74ff7a743f513`.
- Unmodified pinned lint/format passed across **63 Swift files**. Offline tooling,
  CI-whitespace fixtures and whitespace checks passed without baseline changes.
- The corrected **170-check host/native loop** passed, then passed three
  consecutive reruns in the implementation worktree. Sentinel identities and
  raw payloads were absent from the captured production diagnostic records.

Normal-path logs: `build/discovery-visibility-{frozen-full,lint,format,tools,ci-whitespace}.log`.
Implementation logs: `build/discovery-visibility-{copy-green,focused-repeat,permission-final}.log`.
Both worktrees were clean at the implementation commit before this evidence-only
addition. **Independent review is still required before integration.** No merge,
push, main-build replacement, installation, app relaunch/quit, live helper/device
operation, live preference change or permission request was performed. The live
discovery/radio cause and hardware acceptance remain open.

## Main integration · 2026-10-16

Only the two authorized visibility commits integrated, without conflicts, on main
`52ae53e`. The separately pending native fallback `6c59dc9` was not integrated.
Existing untracked `.worktrees/` user work was preserved.

| Reviewed source | Main commit |
| --- | --- |
| `5fcc364` — saved-target copy and typed discovery evidence | `61548f1` |
| `a591220` — frozen source validation | `5feb438` |

The parent supplied independent **CLEAN** review with four 170-check focused runs,
39 permission-context checks, 81 diagnostic checks and unmodified 63-file lint.
Its separate full run was pending when integration started; no result from that
run is claimed here. Production, tests and compiler inputs exactly match the
reviewed source branch. Gesture C safety, bounded asynchronous diagnostics,
HostTransactions, typed login and earlier UUID-owned error clearing remain intact.

Two integrated full-run attempts at
`5feb4386cde7db87e7afba7e0298906b8ec8a989` hit harness deadlines: 600 seconds during
the app build, then 1,200 seconds after app/packaging/compiler fixtures and policy
tests, before the legacy compile completed. Both passed the auxiliary 81 diagnostics,
114 C and 39 permission checks first. Neither partial run is full-suite success.
Logs: `build/bluetooth-discovery-integration-clt-{timeout,timeout20}.log`.
The unchanged suite was then rerun in the background with timestamped top-level
steps and no harness deadline. Its completion notification reported **exit 1**,
not a timeout: the native first-display-click assertion failed. No full-suite
pass or 4,765-main-legacy result is claimed.

### Completed main validation and native-test blocker

The timestamped run started at `16:18:06Z`; app build ran `16:18:46Z–16:19:21Z`
(35 seconds), legacy compilation `16:19:24Z–16:19:45Z` (21 seconds), then the
legacy executable reached and failed:

```text
FAIL: stable popup's first display-control click acts without an activation/loading click
```

Log: `build/bluetooth-discovery-integration-clt.log`, also preserved as
`build/bluetooth-discovery-integration-clt-first-click-failure.log`. The first two
attempts were interrupted by foreground **tool deadlines**, not an observed app
hang. Their logs lack per-step timestamps; no compiler-stall cause is inferred
from them. The timestamped completion demonstrates that the unchanged compilation
can finish; it does not explain those earlier delays.

`build/isolated-tests --presentation-display-refresh-regressions` reproduces that
same failure alone (`build/bluetooth-discovery-integration-presentation-focused.log`),
before any Bluetooth test runs. A temporary diagnostic test copy shows a fresh
snapshot (`settling=false`, `snapshots=1`), a non-key popup and zero action callbacks
after the synthetic click. A separately compiled focused executable with all
changed Swift inputs restored byte-for-byte from pre-integration `52ae53e` also
fails at that exact assertion. Logs:
`build/bluetooth-discovery-integration-first-click-{probe,baseline}.log`.
Temporary probes are isolated under the named `visibility-first-click-probe.*` /
`visibility-first-click-baseline.*` debug directories recorded in those logs;
no production or tracked test source was edited. This isolates a failure that
does not require the visibility changes; the native event/focus cause remains
unresolved. No guard, assertion or default-suite path was weakened or skipped.

Completed checks at exact main source
**`5feb4386cde7db87e7afba7e0298906b8ec8a989`**:

| Check | Actual main result |
| --- | --- |
| Full legacy suite | **Failed** at the assertion above; no completed legacy total |
| Focused Bluetooth visibility/recovery | **170 passed**, separately invoked from the compiled main test executable |
| Permission-context | **39 passed** in the full attempt |
| Diagnostics | **81 passed**, plus safety no-flush/no-sync-wait guard |
| Offline instant C safety | **114 passed** |
| Swift Testing policy | **10 tests / 3 suites passed** |
| Mocked installer | **13 passed**, separately invoked after the full attempt stopped |
| App/compiler/packaging | Passed before the native failure, including complete notices, real/relocated bundle and explicit compiler inputs |

The focused 170 path is normally inside the legacy suite; its separate success
does not establish or add to a 4,765 legacy pass count. Logs:
`build/bluetooth-discovery-integration-{focused,installer,metadata}.log` and the full
attempt above. Metadata checks passed with standalone CLT / Swift 6.4 / SDK 27.0,
explicit unset `SDKROOT`, arm64/macOS 15+, version `0.4`, build `4`, strict
configured-certificate signature and exact embedded tested revision. Complete
project/vendor license and provenance files compare byte-for-byte.

Unmodified normal-path lint and format-check passed across **63 files**; offline
tooling and CI whitespace fixtures passed. No lint baseline, rules, exclusions,
build/test scripts or CI configuration changed. Logs:
`build/bluetooth-discovery-integration-{lint,format,tools,ci}.log`.
All **17 shell inputs**, compiler-input ownership, unchanged suite wiring,
manual-UUID/login-binding preservation and fallback-exclusion assertions passed.
All **263 local links and 54 fragments across 36 tracked Markdown documents** and
`git diff --check` passed. Probe instrumentation exists only in the isolated debug
copy, not in committed source.
The 170-check focused host/native path also runs inside the legacy suite through
`runUITests` → `runBluetoothErrorRecoveryTests`; it is not an additional legacy
count or a new set of 170 independent assertions.

Saved choices survive successful empty inventory; copy no longer asks users to
choose those targets again. Typed scalar discovery diagnostics keep helper
authorization/source **unknown**, distinguish parsed versus published inventory,
deduplicate states and exclude identities/raw payloads. They issue no extra helper
commands and do not authorize actions. This adds no automatic radio power action,
permission-denial inference or claim that the underlying radio/discovery failure
is fixed. The full desktop/keyboard freeze cause remains unknown.

No production app launch/quit/relaunch/install, live Bluetooth query/toggle/device
action, permission/TCC or live preference change, login registration, push/tag or
publication was performed. The current app process was preserved; rebuilding the
bundle does not update its loaded image. Existing isolated-suite read-only
capability/file checks remain. Hardware/native and hosted-CI acceptance remain open.
The separate docs-only evidence commit does not claim a rebuild at its own revision.

Follow-up: the [native fixture coordinate diagnosis](presentation-display-refresh.md#native-fixture-coordinate-correction--2026-10-16)
reproduces the first-click failure with a WindowServer-transformed popup and corrects
only synthetic fixture targeting. It retains the exact production-policy negative
control. The failed integrated-main run above remains failed; separate branch
validation is recorded in that follow-up, not retroactively attributed to main.
