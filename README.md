# Fix macOS

A source-built macOS menu-bar app for display recovery, window layouts, audio,
input controls, and other opt-in desktop tools.

Requires **Apple Silicon and macOS 15+**, Xcode Command Line Tools
(`xcode-select --install`), and [Homebrew](https://brew.sh). Development evidence
includes macOS **26.6.2 (25G83)**; the deployment target does not establish acceptance
on every supported OS. This repository provides source installation, not a
notarized binary release.

## Built-in modules

These are **built-in feature modules**, compiled into the app and running in its
process. They are not downloadable plugins. You can enable them independently;
some share system-control owners. There is no dynamic loader or unified plugin
registry. See [MODULES.md](MODULES.md) for source owners, UI, lifecycle, and test seams.

Fresh installations start with features off and an empty quick-action layout.
Existing installations keep their preferences. Enable features in Settings or run
guided setup; permission grants belong to macOS and survive setup cancellation.

| Module | What you get | Quick action | Settings group |
| --- | --- | --- | --- |
| Monitor switching | Turn individual screens on/off with last-display protection and recovery. | Displays | Displays |
| Display arrangement | Drag screens into place, close gaps, and match cursor crossings across unequal edges. | Displays editor shortcut | Displays |
| Bluetooth reconnect | Reconnect chosen devices, connect/disconnect on demand, and protect other headphones. | Bluetooth | Sound & connections |
| Audio | Choose microphone/output independently, with preferred routes and fallbacks. | Audio | Sound & connections |
| Animations | Reduce selected system effects; optional fast desktop switching under Advanced. | Settings only | System |
| Menu bar | Experimental compact icon spacing and a movable hiding divider. | Menu-bar chevron | System |
| Hold to quit | Hold ⌘Q through an app-named countdown to prevent accidental quits. | Keyboard shortcut | Input |
| Keep awake | Timed or running-app idle-sleep prevention, with optional display wake. | Keep awake | System |
| Window positions | Save named layouts and restore on demand or after reconnect/wake; Pause and app exclusions. | Window layouts / Displays | Displays |
| Clipboard | Search text/PNG history, copy back, pin/delete entries, and exclude apps. | Clipboard / ⌘⇧V | Clipboard |
| Mouse | Apply mouse-class acceleration/tracking overrides and restore original runtime values. | Settings only | Input |

### Behavior and defaults

**Displays:** default **Dangerously** mode acts immediately; **Safely** offers a
20-second undo. Both protect the last usable display. Arrangement changes require
confirmation; display changes last for the login session. Window restore reports
missing, ambiguous, and unsupported windows instead of guessing a match.

**Audio:** automatic routing starts off and polls device changes every two seconds.
Manual changes pause that direction until a device-list change or Resume.
**Keep awake:** custom durations accept 1–1440 whole minutes, with +15 minutes and
presets. Stop pauses matching app reasons; Resume restores them. Timed sessions
do not survive relaunch.

**Clipboard:** select an entry, then press Return or click **Copy** to copy and
dismiss without pasting. See privacy and retention below. **Hold to quit:** the
default is three seconds (1–99); releasing early, switching apps, or clicking cancels.
Normal quit requests preserve save prompts; other quit commands remain unchanged.

**Mouse:** Apply changes IOKit runtime values, not system preferences; disable/quit
restores captured values. Relaunch/reconnect does not reapply overrides. Readback
checks API results, not physical effectiveness. Per-device and wheel controls are
unsupported. **Animations:** turning the preset off restores prior settings; effects
vary by app and do not suppress all Mission Control/Control Center motion.

**Menu bar:** spacing and hiding start off. ⌘-drag the divider left of the chevron
and extra icons left of the divider. Click the chevron to hide/reveal; quitting
reveals icons. Spacing may require app relaunch/logout. There is no notch-overflow panel.

The popup contains editable quick-action widgets. **Edit** supports Add, ordering,
compact/expanded presentation, Remove, and Restore suggested; **Done** saves and
**Cancel** discards the draft. Removing a widget does not disable its feature or
clear its data. Safety/recovery controls and an active awake session's Stop remain
reachable without widgets. Clipboard widgets do not preview content.

The gear opens one reusable, resizable **Settings** window: General, Quick actions,
Displays, Sound & connections, Input, System, and Clipboard. **General → Run setup
again** starts from current choices. Only **Finish** applies setup configuration;
Mouse tuning still requires explicit Apply. Setup does not move windows, rearrange
displays, or start timed awake sessions. Feature activation can start reviewed app
awake rules, Bluetooth reconnect, or audio routing; animation changes may restart
Dock/Finder. Setup reports per-feature outcomes and pending access/hardware.

## Clipboard privacy and retention

Capture starts **paused each launch**. History defaults to memory-only, with at most
100 entries, UTF-8 text up to **64 KiB**, and **PNG only**, up to **4 MiB per image**
and **32 MiB total image bytes**. Pins bypass age expiry, not hard caps.

Optional disk retention stores an **unencrypted JSON archive**, including image
bytes, at `~/Library/Application Support/Fix macOS/Clipboard/history.json`. Choose
1–365 days for unpinned entries. Turning disk retention off deletes the archive;
Clear deletes history including pins. Failed cleanup stays pending with retry and
can block module unload or quit. Turning the Clipboard module off stops its work
but does **not** turn retention off or erase the archive. Capture and retention are
separate choices.

The app samples the clipboard every **500 ms** and can miss intermediate copies.
App exclusions use the foreground app at sampling time, not proven clipboard
authorship. Concealed, transient, and autogenerated formats are skipped. These
filters cannot guarantee that other apps label sensitive content correctly.

## Install and update from source

```sh
curl -fsSL https://raw.githubusercontent.com/jakub-tucek/fix-mac-os/main/install.sh | bash
```

The installer installs Bluetooth dependencies, keeps its checkout in
`~/Library/Application Support/Fix macOS/source`, and installs to
`~/Applications/Fix macOS.app`. Rerun to update. It skips unchanged revisions;
use `| bash -s -- --force` instead of `| bash` to force a rebuild, including when
changing signing configuration. It stops rather than overwriting local source changes.

**Settings → General → Updates** checks GitHub source history on `main`, with a daily
automatic check and a manual check. Installer-managed copies offer **Install update…**
in Terminal and quit the old app before replacement. Updates follow source commits,
not release versions. The app downloads `install.sh` at the offered SHA, but that
installer fetches/builds the latest `main`; it does not guarantee the exact offered SHA.

Without a certificate, builds use ad-hoc signing; macOS may require renewed permission
grants after updates. Set `MAC_UTILS_SIGNING_IDENTITY` when running the installer to
save a local signing identity. No certificate or notarization service is included.

For a manual build:

```sh
brew install blueutil switchaudio-osx
bash build.sh
open "build/Fix macOS.app"
```

Enable **Launch at login** in Settings if wanted. Developers can run isolated checks
with `bash test.sh`.

## Permissions and limits

- **Accessibility:** desktop switching, matched screen edges, hold to quit, and
  Accessibility-based window capture/restore. Grant access for the features you use.
- **Bluetooth:** contextual authorization for device management.
- **Microphone / Screen Recording:** selecting an audio input does not record it.
  Production features do not require microphone recording or Screen Recording access.

Display and gesture features use private macOS APIs. Physical monitor recovery,
trackpad behavior, mouse effectiveness, audio hardware, and live accessibility/focus
checks still have acceptance gaps. The watchdog cannot guarantee recovery from a
stalled WindowServer or graphics driver. Window restoration covers ordinary accessible
windows on the current desktop, not full-screen windows or Space assignments.

## Documentation

- [Module owners, source layout, and vendored-engine rationale](MODULES.md)
- [Current acceptance matrix and historical evidence](VALIDATION.md)
- [UI implementation record and remaining native acceptance](UI-UX-PLAN.md)
- [Development roadmap and unsupported work](ROADMAP.md)
- [Unreleased 1.0 notes draft](RELEASE-NOTES-1.0-DRAFT.md)
- [Host admission and quit terminology](GLOSSARY.md)

## Credits and license

[MIT](LICENSE). Thanks to these projects and authors:

- [strafe](https://github.com/rileycx/strafe), Riley Hennigh (MIT): embedded Space-switching engine.
- [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher), jurplel (MIT): original switching technique.
- [iss](https://github.com/joshuarli/iss), joshuarli (0BSD): upstream gesture payload implementation.
- [blueutil](https://github.com/toy/blueutil) (MIT): Bluetooth control.
- [switchaudio-osx](https://github.com/deweller/switchaudio-osx), Devon Weller (MIT): audio device selection.

Complete vendored notices appear in [Vendor/strafe/LICENSE](Vendor/strafe/LICENSE);
[UPSTREAM.txt](Vendor/strafe/UPSTREAM.txt) records the import and local patches.
We vendor only strafe's gesture engine/interceptor, C payload code, and their
dependencies, pinned at `37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7`, not the upstream
app. Our raw Swift/C build compiles that source with a local queue-cancel/drain patch
and an injectable phase poster for tests. This keeps the dependency pinned and the
integration patch under source control; it is not a plugin. See
[why strafe is vendored](MODULES.md#why-strafe-is-in-vendor).
Before distributing app bundles, verify inclusion of the required notices. This
documentation does not assert that pending packaging changes have landed.
