# Guarded deployment and restart checks · 2026-10-27

Source: changes based on `590b3e5`, committed with this record.

The previous workflow rebuilt/restarted the daily app for each small edit, deleted
the old bundle before readiness checks and omitted local source-install metadata.
The new workflow uses isolated previews and a shared guarded deployment transaction.
See [commands, session policy and rollback](../deployment.md).

## Isolated evidence

`build/deployment-validation.log` records `tail -n +9 test.sh | bash -e` passing:

- **5,424 isolated checks**, including actual local notification request/reply,
  expired-request rejection, host update-session veto, injected active Keep awake
  preservation, setup checkpoint flush and separate-process restart persistence
  for alias references, widgets, module choices and staged setup.
- **12 deployment transaction tests** with temporary bundles and fake OS operations:
  signature rejection, preflight deferral, late host veto, failed swap, failed health,
  rollback, rollback veto, no-open reporting, offline startup, stale/wrong-session/
  wrong-revision/configuration checks, readiness regression and bounded backups.
- **45 native UI checks**, including the actual Links alias editor rendered against
  simulated browsers. Both Links and setup have interactive preview modes.
- **10 policy tests in three suites**, feature-index and Bluetooth checks,
  packaging/build fixtures and **13 source-installer scenarios**. The shared
  deployment transaction now owns swap/rollback coverage previously embedded in
  the installer mock.

Pinned lint/format, developer-tool fixtures, shell syntax and whitespace checks pass.

The first integrated pipeline stopped in the installer fixture because a metadata
path contained a doubled slash from `TMPDIR`. Canonical `Path` comparison fixes
that without changing the configured destination. The final integrated run above
passes. `build/deployment-install-debug.log` retains the earlier failure trace.

`build/deployment-full-test.log` still stops at the existing gate:
`Fixture requires macOS 27 augmented payloads; refusing different payload path.`
The preceding state/diagnostics/reader fixtures passed; this is not a full-suite pass.

## Live acceptance

The user authorized one legacy-bootstrap restart after saving transient work.
At this commit, installation/readiness evidence is pending. The old `590b3e5`
process cannot answer the new endpoint, so the first upgrade cannot supply a
verified pre-update configuration/permission baseline. Its normal quit remains
responsible for recovery. A later evidence entry records the actual result.

Checks do not establish physical-device, VoiceOver or minimum-OS acceptance.
Health is readiness reporting, not a hardware exercise. Recovery of a hung new
GUI, power loss during publication and live rollback remain unverified; failures
retain bundles and require normal host-approved quit rather than force termination.
