# Fix macOS 1.0 release notes · draft

**Unreleased. Version/build: TBD.** “1.0” names a proposed future release, not the
current app version. At source baseline `f359f42`, `Info.plist` still declares
**0.4 / build 4**. This docs-only change does not bump versions, create a tag, or
publish a release.

## Candidate scope

- Direct quick-action widgets, a reusable Settings window, and opt-in guided setup.
- Display switching/recovery, arrangement and matched edges; named window layouts
  with optional reconnect/wake restoration.
- Independent microphone/output selection, preferred routes and Bluetooth reconnect
  policies, timed/app-based keep awake, and hold-to-quit protection.
- Paused-by-default clipboard capture, searchable text/PNG history, pins, exclusions,
  and separate opt-in unencrypted JSON retention.
- Opt-in mouse-class runtime tuning, selected animation reductions, and experimental
  menu-bar spacing/hiding.

See [README.md](README.md) for defaults, permissions, limits and source installation.
The app targets Apple Silicon/macOS 15+; recorded development evidence includes
macOS 26.6.2. We do not claim a notarized binary workflow, universal animation
suppression, per-device mouse/wheel controls, cross-Space window restoration, a
notch-overflow panel, SQLite history, or plugins.

## Open release blockers and integration checks

At the `f359f42` audit baseline, the parent session tracks these defects:

- Display recovery can report a stale disabled-display count.
- Guided setup can mishandle keep-awake assertion state.

Separate implementation work is pending. Keep these open until the final merged
tree includes the fixes and regression evidence; this draft does not claim them fixed.

The release owner must also record final merged build/test results, signing-identity
rebuild behavior, and inspection of bundled third-party notices. Packaging work is
pending at this baseline. The source vendor file includes strafe and
InstantSpaceSwitcher MIT notices plus the joshuarli/iss 0BSD notice; verify the
distributed app contains required notices rather than assuming source presence is enough.

The parent owns the release checklist. This draft does not replace that checklist
or certify completion of its review gates.

## Acceptance limits

The baseline report records 3,997 isolated checks plus seven installer checks.
Tests with fake backends, fixture renders, source parity, and native compilation
do not establish physical hardware or live accessibility acceptance. See the
[current matrix](VALIDATION.md) for remaining display, gesture, audio, mouse,
sleep/lid-close, clipboard focus/shortcut, VoiceOver and UI checks. No app/system
actions or full-suite run occurred for this documentation audit.

Source updates compare commits on `main`, not release versions. The updater pins
the installer download to the offered SHA, but the installer builds latest `main`.
An update does not guarantee an exact offered-SHA build. Ad-hoc signing may require
renewed permission grants after replacement; a signing certificate is not included.

## Before publication

Replace TBD only after the release owner chooses a version/build. Update this draft
with final integrated revisions, remaining accepted limitations and live evidence.
Do not turn pending fixes or historical CLEAN reviews into release-wide acceptance.
