# Better macOS

**A menu-bar app for window layouts, displays, audio, clipboard history, and everyday macOS annoyances.**

Snap a window across monitors. Keep your Mac awake during a task. Pick speakers and microphone separately. Find something you copied earlier. Better macOS puts these controls in one app, with each feature enabled separately.

Fresh installs start with features off. Choose what you need in guided setup or Settings, then add your everyday controls to the menu-bar popup.

## What it does

| Feature | What you get |
| --- | --- |
| Windows | Tile with Rectangle-style shortcuts or a visual action palette. Save named layouts and optionally restore after display reconnect/wake. Repeated left/right tiling continues across neighboring screens. |
| Displays | Turn screens on/off, arrange them, and match cursor crossings across unequal edges. Last-display protection and recovery remain available. |
| Audio | Choose output and microphone independently; set preferred devices and fallbacks. |
| Bluetooth reconnect | Reconnect chosen paired devices or connect/disconnect manually when helper reads are verified. Conflicting helper/macOS status blocks control. |
| Keep awake | Prevent idle sleep for a timer or while selected apps run, optionally keeping the display awake too. |
| Clipboard | Search text/PNG history with ⌘⇧V, pin entries, and copy them back without automatic paste. Capture is opt-in and paused each launch. |
| Hold to quit | Hold ⌘Q through a countdown to avoid accidental quits. |
| Animations | Reduce selected system effects, with optional fast horizontal desktop switching. Some animations remain. |
| Menu bar | Experimental icon spacing and a divider for hiding less-used icons. |
| Mouse | Experimental mouse-class acceleration/tracking overrides with explicit Apply and Restore. |

## How you use it

- **Left-click the menu-bar icon:** your chosen quick-action widgets.
- **Right-click:** Window actions, Quick actions, Keep awake, Settings, and Quit.
- **Settings:** seven tabs for configuration; **General → Run setup again** revisits setup.
- **Quick actions → Edit:** add, reorder, or remove widgets. Removing a widget does not disable its feature or delete its data.

Window and Keep awake palettes offer larger, keyboard-navigable controls. Opening a palette changes nothing until you choose an action. [Usage, shortcuts, and defaults →](docs/usage.md)

## Install from source

Requires **Apple Silicon, macOS 15+, Xcode Command Line Tools** (`xcode-select --install`), and [Homebrew](https://brew.sh). Intel Macs are not supported. [Tested toolchains](docs/development.md#host-and-compiler).

```sh
curl -fsSL https://raw.githubusercontent.com/jakub-tucek/better-macos/main/install.sh | bash
```

This runs a source installer: it downloads the repository, installs `blueutil` and `switchaudio-osx`, builds locally, and opens `~/Applications/Better macOS.app`. During an update it asks the running app to quit normally before replacement. [Installer options and signing](docs/usage.md#source-installation-and-signing).

**Update:** rerun the command, or use **Settings → General → Updates → Install update…** for installer-managed copies. Updates build latest `main`, not a pinned release. Ad-hoc-signed updates may require renewed macOS permission grants. No notarized binary release is provided.

## Before enabling features

- **Permissions are contextual.** Window actions, matched edges, desktop switching, and Hold to quit need Accessibility. Bluetooth management needs Bluetooth access. Audio input selection does not record sound; production features need neither microphone-recording nor Screen Recording permission.
- **Clipboard disk history is optional and unencrypted.** Capture, retention, and deleting history are separate choices. [Privacy and retention](docs/usage.md#clipboard-privacy-and-retention).
- **Some controls use private macOS APIs.** Display/gesture recovery cannot guarantee recovery from a stalled WindowServer or graphics driver. Bluetooth reconnect remains blocked on helper/native disagreement; the native probe is not a control fallback.
- **Scope has limits.** No cross-Space/full-screen window restore, per-device mouse or wheel controls, notch-overflow panel, or runtime plugins. Live hardware and VoiceOver checks remain open. [Validation and known gaps](docs/validation/README.md).

## Build and contribute

From a checkout on the supported Mac/toolchain:

```sh
bash build.sh  # build and sign build/Better macOS.app; does not launch
bash test.sh   # isolated tests, build/packaging checks, installer fixtures
```

[Developer setup](docs/development.md) · [Source map](docs/modules.md) · [Documentation](docs/README.md) · [Roadmap](docs/roadmap.md)

[MIT license](LICENSE). [Source credits and bundled notices](docs/modules.md#documentation-and-source-credits).
