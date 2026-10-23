# Bluetooth power-on timeout diagnosis and owned-error recovery

Base: `e58dfe9`. Diagnostic branch: `diagnose/bluetooth-exit75`.
The screenshot is from an existing process whose loaded revision is unknown;
replacing its bundle does not establish that it runs this source.

## Scope and safety

No app launch/quit/install, live Bluetooth power or connection command,
permission probe/request, or live preference mutation. Installed
`/opt/homebrew/bin/blueutil` was invoked only with `--version` and `--help`;
both report 2.14.0. Tests substitute authorization, Bluetooth CLI, audio backend,
and isolated UserDefaults. Compilation/signing occurs in this new worktree only.

## Source trace at the base revision

- `Sources/SharedUI/Dashboard.swift:874-877`: non-draft Bluetooth UI offers
  **Turn Bluetooth on** when the observed radio is off.
- `Sources/App/AppDelegate.swift:332`: callback passes through host admission,
  then calls `BluetoothModule.turnBluetoothOn()`.
- `Sources/Features/Bluetooth/BluetoothModule.swift:411-448`: explicit manual
  request is queued behind current work, calls `turnPowerOn`, and reports errors.
- `BluetoothModule.swift:67-69`: the only production `--power 1` invocation;
  successful helper execution is followed by radio-state verification.
- `Sources/Core/CommandRunner.swift:17-20,49-55`: power commands get a 15-second
  app deadline. Nonzero helper exit preserves stderr and produces the exact
  `blueutil failed (exit 75): ...` prefix.
- `BluetoothModule.swift:498-505` -> `AppDelegate.swift:529,1141` ->
  `Sources/SharedUI/Dashboard.swift:214`: manual failures reach the global string.
- `Sources/SharedUI/UISurfaces.swift:129,694-697`: all Settings destinations,
  including General, render that global string in orange. It is not a General
  feature failure and is not a watchdog diagnosis.
- `AppDelegate.swift:522-530` activates Bluetooth with `start()`;
  `BluetoothModule.swift:330-337,351-393` polls at startup and every five seconds.
  `reconcile` (`95-100`) observes power/devices and returns without reconnecting
  if power is off. It never turns the radio on; polling errors use
  `reportError: false` and do not publish the global error.
- Setup discovery (`AppDelegate.swift:716-717`) only lists devices. Setup Finish
  (`834-847`) applies selected targets/protection/reconnect policies; it does not
  invoke the power action. Manual connection (`BluetoothModule.swift:84-86`)
  refuses when the radio is off instead of powering it on. No watchdog caller
  reaches the power-on method. Global source search found only the manual path.
- Successful cycles clear the feature error (`BluetoothModule.swift:484`) and
  host refresh projects current feature status (`AppDelegate.swift:934-964`),
  but neither clears the previously published global string.

## External helper evidence

Upstream blueutil v2.14.0, commit
`60d8411fa3f9968ab6f05e198b486fe89961e18f`, `blueutil.m:167-187`:
`BTSetParamState` returns immediately if already in the requested state;
otherwise it calls the IOBluetooth preference setter and polls its getter for
100 x 100 ms. If the getter never reports the requested state it emits:

```text
Failed to switch bluetooth power on in 10 seconds
```

`blueutil.m:1033-1036` returns `EX_TEMPFAIL` (75) on that failure. Installed
`--help` independently labels 75 **Timeout error**. The app's 15-second deadline
is not this 10-second timeout. Raising that deadline does not change the helper's
own loop. This does not determine whether the OS daemon, helper compatibility,
permissions, hardware, or another controller caused the failed transition.

Source: <https://github.com/toy/blueutil/blob/60d8411fa3f9968ab6f05e198b486fe89961e18f/blueutil.m#L167-L187>

## Reproduction loop

`Tests/BluetoothErrorRecoveryTests.swift` is called by `runUITests`
and included in the worktree's `test.sh` compiler inputs. It uses the real
`AppDelegate`, Dashboard callbacks, Bluetooth module, and `CommandRunner` with
an executable named `blueutil` in an invocation-owned temporary directory.

1. Enable Bluetooth through the host with saved automatic reconnect enabled
   and fake radio off: assert only state/discovery commands, no power-on.
2. Assert a preexisting unrelated global error survives healthy observation.
3. Invoke the actual host power-on callback. Fixture emits the exact screenshot
   stderr and exit 75: assert feature and global errors equal the screenshot.
4. Successful polling clears feature error but leaves the global screenshot text.
5. Change only the fixture's power-command outcome to success. Before the fix,
   explicit retry verifies radio on and no feature error, but the global banner
   remains. The desired-recovery assertion failed on this exact case before
   production changes (`bluetooth-exit75-red.log`).

After the fix, verified retry clears its owned banner. Further regressions prove
failed retry remains visible, newer unrelated and identical-text publications
survive success, healthy discovery with radio still off cannot dismiss the action
failure, and a successful power action cannot resolve a failed device connection.
A verified retry of that same connection can resolve its banner. Disable neither
mutates Bluetooth nor clears an unrelated storage error.

First `BETTER_MACOS_SIGNING_IDENTITY=- bash test.sh` run: all nine diagnostic
assertions passed, with the exact screenshot text and stale-after-success state.
The overall runner subsequently failed the existing fresh-install-detection
assertion because the newly inserted diagnostic ran before it and registered
Bluetooth/Audio fallback defaults in the process-wide registration domain.
The interim reordered run passed, but reordering was not accepted as the final
isolation fix. The fixture now snapshots and restores the process-wide registered
defaults as well as removing its unique persistent domain, and runs **before**
the existing fresh-install checks. Those checks pass with the fixture first.
Preserve the initial failure: `bluetooth-exit75-test.log`; pre-fix reordered run:
`bluetooth-exit75-reordered-test.log`.

## Focused fix

The Dashboard retains its existing optional global error string. A lightweight
publication generation changes on every assignment, including identical text.
Bluetooth reports the typed identity and result of completed manual operations;
polling does not claim to resolve manual intent. The host associates the generation
of a published failure with its manual operation. Only verified success of the
same operation may clear that exact generation. A newer error from displays,
storage, login, or any other publisher therefore survives. Disabling drops the
owner's completion callback and ownership token without dismissing errors.

No error suppression, timeout change, implicit power-on, automatic retry, logging
framework, reconnect policy, audio opt-in, or Settings layout change is included.

## Validation · 2026-10-15

Validated the implementation working tree based on `e58dfe9`, before committing:

- Red: the real host/CLI regression failed at **verified successful retry clears
  only its owned Bluetooth failure banner** before production changes.
- Green: complete `BETTER_MACOS_SIGNING_IDENTITY=- bash test.sh` passed **4,395
  isolated checks**, **10 Swift Testing tests / three suites**, **13 mocked
  installer scenarios**, state/compiler, four build fixture groups, complete
  notices, strict ad-hoc signature and real/relocated-bundle checks.
  Log: `bluetooth-error-recovery-full.log`.
- A second direct `build/isolated-tests` run passed the same **4,395 checks**:
  `bluetooth-error-recovery-repeat.log`. The fixture runs before fresh-install
  detection; registered defaults are restored, not hidden by reordering.
- Pinned SwiftLint and SwiftFormat passed across **48 first-party Swift files**;
  offline tooling fixtures passed. Initial tooling runs in the `/private/var`
  worktree failed because `/var` aliases broke baseline/exclusion matching,
  including checks incorrectly entering generated SwiftPM sources. No baseline,
  rules, production sources or tooling scripts were changed to accommodate this.
  Checks instead ran against a byte-compared Sources/Tests/scripts/config snapshot
  at `/Users/jakubtucek/Projects/others/better-macos-bt-tools.vz7dZk`, with the same
  checksum-verified pinned tools. Logs: `bluetooth-tooling-{lint,format,fixtures}.log`.
- `bash -n test.sh` and `git diff --check` passed.

These are isolated source checks, not live hardware/permission acceptance. The
precommit test bundle embeds the base HEAD; this is not a final release-artifact
claim. Independent review and combined-parent integration validation remain with
the parent; preserve the parallel Bluetooth logging work when integrating.

## Ranked falsifiable hypotheses

1. **External helper/OS power-on timeout.** Predicts the helper-owned error/75
   is preserved through the production runner; a larger app deadline will not
   alter blueutil's 10-second state loop. Upstream source supports this mechanism;
   the user's live underlying reason remains unknown.
2. **Historical global banner after recovery.** Predicts feature success clears
   `lastError` but not Dashboard `errorMessage`, including successful explicit
   power-on retry. The isolated reproduction tests this without any live hardware.
3. **Older loaded source has different power-on triggers.** Predicts identifying
   the loaded revision will reveal another call path if no manual action occurred.
   Cannot test against current-source fixtures; app identity/trigger remains open.

## Remaining information and scope

Ask whether the message first appeared at startup, after setup Finish, or after
clicking a Bluetooth action, and whether Bluetooth subsequently turned on. Do not
infer the current source is loaded in the preexisting process.

The parent approved only the narrow owned-error recovery correction above;
feature-scoped presentation and general dismissal redesign remain out of scope.
Merely clearing every error on a successful poll is unsafe:
discovery can succeed while the radio is still off and the requested action remains
unsatisfied. Do not suppress genuine helper failures or introduce automatic power
toggles/retries without explicit intent; preserve reconnect/audio opt-ins.

## Main integration · 2026-10-15

Independently reviewed CLEAN source `f60041a9c739ec958b9a26edf30547b2debafc3e`
integrated without conflicts as **`3cda8e9946971af8cb63b16f91351019c184a7db`** on
clean main `e58dfe9`. Existing user history, KeepAwake ownership, organized paths,
SwiftPM policy inputs and CI were preserved. Pending login and diagnostic-logging
work was not integrated.

This fixes **stale manual-action error presentation only**. The host records an
operation and the UUID of its published failure; only verified success of that
same operation can clear that same publication. Newer errors, including identical
text, survive. Observation alone does not dismiss an unsatisfied action. This does
not diagnose/fix the live exit-75 cause, change power timeouts/reconnect policy,
prove radio recovery, identify the loaded app revision or close hardware acceptance.

At the integrated revision, one complete `bash test.sh` passed **4,395 legacy
checks**, **10 Swift Testing tests in three suites**, **13 mocked installer
scenarios**, production compiler/package/build fixtures and real/relocated signed
bundle checks. Log: `build/bluetooth-error-recovery-integration.log`. It records
HEAD, scoped Xcode 27 / Swift 6.4 / SDK 27.0 compiler/SDK paths and versions, arm64
and bundle metadata with `SDKROOT` explicitly unset. No additional suite repeat
was needed; the source worktree's repeat evidence above remains historical.

Strict configured-certificate signature, complete notices, source/built plist lint
and metadata passed: the arm64/macOS 15+ bundle embeds the tested revision, version
`0.4`, build `4`, SDK 27.0. Pinned lint/format passed directly in main across **48
files**; offline tooling and CI whitespace fixtures passed. Logs:
`build/bluetooth-error-recovery-integration-{lint,format,tools,ci}.log`.

No real app launch/quit/install, live Bluetooth/device command, permission request,
live preference mutation, version bump, push/tag or publication was performed.
Fixtures use injected backends and isolated preferences; no hardware fix, hosted CI
result, new minimum-toolchain acceptance or final artifact at the evidence commit
is claimed. Historical diagnostic failures and native/hardware gates remain open.

All **13 shell inputs**, **234 local links and 38 fragments across 29 tracked
Markdown documents**, scope/input assertions and `git diff --check` passed.
