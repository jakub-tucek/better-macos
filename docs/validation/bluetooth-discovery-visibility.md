# Saved Bluetooth targets and empty discovery · 2026-10-16

Base: `52ae53e`. This corrects popup guidance and adds observation diagnostics.
It does **not** fix the underlying radio/discovery problem or establish hardware
acceptance. No real helper, permission change or app relaunch was used.

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
