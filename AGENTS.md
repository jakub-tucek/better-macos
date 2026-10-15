# Working in Fix macOS
## Read by task

- For feature ownership, shared dependencies, UI entry points or cleanup, read
  [MODULES.md](MODULES.md). Built-in features are compiled into one app, not runtime plugins.
- For architecture/tooling changes, read [ROADMAP.md](ROADMAP.md); proposed packages,
  directories, lint/format tools and CI are not the current developer workflow.
- For testing or release claims, read [VALIDATION.md](VALIDATION.md) and its linked
  revision-bound evidence. Preserve historical failures and hardware acceptance gaps.
- For host coordination terminology, use [GLOSSARY.md](GLOSSARY.md).

## Current commands and layout

Run from the repository root on Apple Silicon macOS with Command Line Tools:

```sh
bash build.sh       # compile, bundle and verify signing; does not launch the app
bash test.sh        # build, packaging/build fixtures, isolated tests, installer fixtures
git diff --check
```

The scripts target arm64/macOS 15+ in Swift 5 language mode. Most first-party Swift
files are at the root; `MouseHID/` is the C boundary and `Tests/` holds test seams.
Update explicit source inputs in both scripts when adding or moving source files.
`build.sh` produces `build/Fix macOS.app`; signing uses `MAC_UTILS_SIGNING_IDENTITY`
or local Git `macutils.signingIdentity`, otherwise ad-hoc. Preserve bundle notices,
strict signature verification and staged replacement/rollback.

## Safety contracts

- `HostTransactions` owns host admission and quit approval. Route actions through
  host guards, including non-UI callers; disabled controls alone are not admission.
  Preserve asynchronous drain, final cleanup checks, veto and canceled-quit reopening.
- Feature owners retain restoration responsibility. Preserve pending recovery and
  retry state after failures, including disabled-feature startup/teardown paths.
  Keep shared Audio/Bluetooth ownership and shared display recovery reachable.
- Input activation requires watchdog/readiness checks. Display disabling requires a ready watchdog;
  restore/recovery must remain available without one. Drain active gestures and cancel queued
  gestures before display changes/shutdown. Preserve last-usable-display and identity safeguards.
- Keep persisted `AppModule` raw IDs, preference keys and existing user choices stable.
  Widget removal is not feature disable or data deletion; Clipboard capture,
  retention and cleanup are distinct choices, with unload/quit vetoes on pending work.
- Setup edits are staged until Finish; cancellation discards drafts, not macOS grants.
  Apply through the host, report per-feature outcomes and preserve explicit Mouse Apply.
- `Vendor/strafe` is pinned and locally patched: preserve gesture cancellation/drain
  and injected test phases. Consult [UPSTREAM.txt](Vendor/strafe/UPSTREAM.txt) and keep
  complete [vendor notices](Vendor/strafe/LICENSE) and project license in built bundles.

## Validation and collaboration

Use isolated preferences/temp files and injected backends; default tests must not
mutate live displays, input, audio, clipboard or system preferences. App launch,
installation and live hardware checks require explicit authorization. Isolated checks
are not native/hardware acceptance. Active core fixes in separate worktrees remain
unresolved until reviewed, integrated and validated at a recorded revision.

User preference: Astra for planning; Sol for background implementation and independent
review when appropriate. Delegate only when authorized; keep reviewer ownership
independent of implementation. Keep parallel work isolated in worktrees and scoped
commits; leave unrelated changes intact.
