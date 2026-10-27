# Development previews and guarded updates

## Iterate without restarting the daily app

Use `bash scripts/dev preview` for Links, or `bash scripts/dev preview --setup`
for onboarding. This runs the actual SwiftUI views in the separate test-host app,
with disposable preferences, simulated browser profiles and simulated permissions.
Its buttons cannot change the default browser, open real profiles or grant access.
Close the preview when finished. `bash scripts/dev ui-test` runs its automated checks.

Batch small edits, validate and commit them, then deploy once when requested.
Builds, commits and pushes do not imply permission to restart the installed app.

## Deploy a committed local build

```sh
bash scripts/dev deploy
bash scripts/dev health
bash scripts/dev deploy --rollback
```

Local deployment requires a clean checkout and the configured persistent signing
certificate. An absent/ambiguous certificate fails before quitting; local deploy
does not fall back to ad-hoc signing. `--destination /absolute/path/Better\ macOS.app`
selects another installation. Build output stays in `build/Better macOS.app`.

The same `scripts/deploy.py` transaction is used by `install.sh` after its source
checkout/build. Local builds embed source path, destination, revision and the
local-development update mode. In-app updates then fast-forward that clean local
main checkout to the exact offered revision and deploy it. Installer-managed
checkouts use their installer path, also pinned to the offered revision. Local
changes, divergent/ahead histories and unavailable revisions stop the update.

### What the transaction does

1. Acquire the destination lock. Build and verify while the old app keeps running.
2. Stage and verify a complete bundle, including notices and source metadata.
3. Ask the live GUI for a fresh main-thread report. Defer if a session would be lost.
4. Ask the host again to prepare for update: checkpoint idle setup, flush preferences,
   and quit through `HostTransactions`. The actual quit and final drain recheck
   session policy. A veto leaves the installed bundle intact.
5. Retain the previous bundle, publish the new bundle and launch it.
6. Wait up to 60 seconds for the expected revision and a new GUI session, a ready
   watchdog, unchanged tracked configuration and no previously-ready check regressing.

Health covers Accessibility, Bluetooth authorization/errors, window shortcuts,
matched edges, Hold to quit, Spaces, Clipboard storage, Links default ownership
and host feature errors. It reads state; it does not grant permissions or exercise
hardware. Already-denied permissions are reported, not mistaken for update
regressions. Watchdog readiness is always required.

`dev health` reads a fresh reply without building or restarting. Each request has
a random nonce, target GUI PID and short expiry; replies identify bundle path,
revision and session. Cached preferences and helper startup logs cannot satisfy
the handshake. Reports contain status categories and a SHA-256 digest of tracked
saved choices, not Clipboard content, URLs, profile names or device identifiers.

## Session policy

| State | Update behavior |
| --- | --- |
| Saved feature choices, Links rules/aliases, widget order | Preserve; compare tracked settings digest after restart |
| Idle setup draft | Save current step/configuration before quit; Resume remains available |
| Setup Apply, display/Bluetooth manual operation, module cleanup | Defer until finished |
| Unsaved Links or widget edits | Defer until Save/Discard or Done/Cancel |
| Timed/app Keep awake, including paused app rules | Defer; never silently end or resume a session |
| Mouse override, pending display restoration | Defer until explicitly restored |
| Manual Audio override | Defer until resolved with Audio Resume |
| Clipboard recording | Defer until paused; startup remains paused |
| Memory-only Clipboard history | Defer; explicitly persist or clear it first, never silently write it to disk |
| Persistent Clipboard history | Existing archive/recovery policy applies; host vetoes pending cleanup |
| Default-browser change | Wait for completion; update/quit never relinquishes the browser |
| Display editor/settings sheet or hidden extra menu-bar icons | Close/reveal before updating |

Ordinary Quit retains its existing behavior; these extra deferrals apply to update
requests. Window-action original-frame caches, Activity history and popup focus
remain process-local, not durable update sessions. This workflow does not transfer
IOKit assertions, event taps or gesture execution between processes.

## Rollback and interrupted deployment

Receipts and bundles live beside the installation under
`.better-macos-deployment/transaction-<UUID>/`. Two successful previous bundles are
retained. Failed/pending transactions remain for recovery; cleanup never selects
unrelated bundles. Receipts identify the installed revision, health result and error.

A failed post-launch check requests normal quit of the new GUI, restores the old
bundle and relaunches it. If the new GUI vetoes or is unresponsive, both bundles
remain and the updater reports the recovery path. It never force-kills or replaces
a running GUI. Rollback restores executable/resources, **not user preferences**;
it must not overwrite settings edited by the user or recovery journals. Automatic
rollback relaunch is not a claim that the old process passed a fresh health check.

`dev deploy --rollback` selects the newest retained previous bundle. An older bundle
without the health endpoint can be restored with `--rollback --no-open`, then opened
manually. `--no-open` always reports health as unverified and retains a rollback copy.

If deployment is interrupted, inspect the receipt and running GUI before removing
the `.better-macos-deploy.lock` directory. Locks are not silently stolen. A stopped
transaction can leave both old and new bundles in its directory.

### First upgrade from an older build

The old GUI cannot answer the new protocol. Save drafts, pause recording and finish
active sessions, then use `bash scripts/dev deploy --legacy-bootstrap` once. This
explicit migration uses normal quit and checks the new process, but has no old
health/configuration baseline. It is accepted only for a bundle without deployment
protocol metadata; it cannot bypass a new host's veto. Later updates use the guarded
path. `install.sh` accepts the same one-time flag for installer-managed upgrades.

## Isolated checks

`python3 Tests/deployment-test.py` exercises replacement failures, active-session
deferral, host veto, post-launch failure, rollback/veto, configuration/readiness
regressions and backup retention using fake process operations and real temporary
bundles. `Tests/DeploymentHealthTests.swift` covers session policy, actual local
request/reply notifications and separate-process preference/checkpoint persistence.
The regular partial pipeline also covers source-installer fixtures and UI previews.
See [validation](validation/deployment.md) for revision-bound results and live limits.
