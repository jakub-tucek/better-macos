# Fix macOS

We love MacBooks. The hardware is hard to beat. But macOS gets in the way far too often.

Fix macOS adds the controls, tweaks, and tools we wish were built in. One modular app: choose what you need and leave the rest off. Disabled modules stop their background work, so you’re not running ten features you don’t use.

| Module | What you get |
| --- | --- |
| Monitor switching | Turn screens on/off with last-display protection and recovery. |
| Display arrangement | Arrange screens and match cursor crossings across unequal edges. |
| Bluetooth reconnect | Reconnect chosen devices and connect/disconnect on demand. |
| Audio | Choose microphone/output independently, with preferred routes and fallbacks. |
| Animations | Reduce system effects; optional fast desktop switching. |
| Menu bar | Experimental icon spacing and hiding divider; no notch-overflow panel. |
| Hold to quit | Hold ⌘Q through a countdown to prevent accidental quits. |
| Keep awake | Prevent idle sleep for a timer or while chosen apps run. |
| Window positions | Save and restore layouts on demand or after reconnect/wake; no full-screen/Space restore. |
| Clipboard | Search text/PNG history with ⌘⇧V. Capture is opt-in, paused each launch; optional local disk retention is unencrypted. |
| Mouse | Experimental acceleration/tracking overrides; no per-device or wheel controls. |

## Install from source

Requires **Apple Silicon, macOS 15+, Xcode Command Line Tools** (`xcode-select --install`), and [Homebrew](https://brew.sh).

```sh
curl -fsSL https://raw.githubusercontent.com/jakub-tucek/fix-mac-os/main/install.sh | bash
```

The installer installs dependencies and builds `~/Applications/Fix macOS.app`. Enable features in Settings or guided setup; fresh installs start with features off.

**Updating:** rerun the same command to build the latest `main`. Installer-managed copies also offer **Settings → General → Updates → Install update…**; this builds latest `main`, not a pinned release. Ad-hoc-signed updates may require renewed macOS permission grants.

[Details, privacy & source credits](MODULES.md) · [MIT license](LICENSE)
