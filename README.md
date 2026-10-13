# Mac Utils

One personal macOS menu-bar app for **monitors, Bluetooth, and fast desktop Space
switching**. Native Swift/AppKit, with on/off switches on the right of each row.
Apple Silicon, macOS 15+; display toggling tested on macOS Tahoe.

## Build and run

Requires Xcode Command Line Tools. Bluetooth uses the same Homebrew tools as the
original auto-connect scripts:

```sh
brew install blueutil switchaudio-osx
bash build.sh
open "build/Mac Utils.app"
```

Look for the sliders icon in the top menu bar. **Settings…** configures device
auto-connect and Space transition speed. **Launch at login** is optional; keep
the built app at a permanent location before enabling it.

## Monitors

- Every connected screen has its own switch, including the built-in screen.
- After switching off, select **Keep … disabled** within 20 seconds or it restores.
- Disabled screens remain listed. The last usable screen cannot be disabled.
- **Enable all disabled monitors**, quitting, or relaunching after a crash restores
  the screens this app disabled.
- Original desktop positions and main-display status are restored when the whole
  original setup is back. A changed plugged-in setup is not rearranged.
- Resolution, brightness and color profiles are not changed. Disable mirroring
  before using monitor toggles.

Uses undocumented `CGSConfigureDisplayEnabled`, dynamically loaded from SkyLight.
It removes a display from the desktop rather than physically powering it off.
Changes are session-only: logout/reboot is the recovery fallback. On Tahoe,
disabled screens disappear from UUID lookup, so recovery retains their previous
IDs for this boot only and rejects IDs assigned to a different visible monitor.
Unplugging or restarting WindowServer while screens are off can prevent recovery.

## Bluetooth

- Paired devices have connection switches. Bluetooth observation and connection
  commands run on a background queue, with timeouts—not on the UI thread.
- In Settings, choose devices for **automatic reconnection**, then enable it.
  Only selected devices are actively reconnected; idle headphones are not probed.
- **Auto** selects reconnection targets. **Audio** marks known headphones/audio
  devices to protect even before macOS registers their audio output.
- By default, other connected Bluetooth audio devices pause reconnection. Audio
  is checked again after connecting before switching the output, protecting
  headphones that arrived during the connection attempt.
- Keyboards do not block reconnecting audio when audio-output discovery is
  available. Without that discovery, any other connected Bluetooth device blocks
  automatic reconnection conservatively.
- Manually disconnecting removes that device from auto-connect, so the app does
  not undo the user's choice. Auto-connect runs only while Mac Utils is running.
- Device addresses and preferences stay in local UserDefaults. No telemetry.

### Migrating the previous Bluetooth tool

The app can import the speaker selection from the old `smart-connect.sh` under
`~/Projects/others/bluetooth-connect/bluetooth-connect/`. It never edits that script.

If `com.user.bluetooth-autoconnect` is installed, Mac Utils leaves its reconnect
loop in charge until **Settings → Take over existing Bluetooth service…** is
confirmed. This stops/disables the old LaunchAgent and enables Mac Utils's loop.
Its script and plist remain intact. Enable **Launch at login** if wanted.

## Desktop Spaces

Embeds the gesture engine/interceptor from [strafe](https://github.com/rileycx/strafe)
in the same app—no second strafe process or menu icon. **Fast Space switching**
supports Instant, Quick and Smooth speeds. This affects trackpad Space-switching
transitions, **not all macOS animations**. It does not include strafe's keyboard
shortcuts or standalone CLI.

Accessibility permission is required **only** for this feature. Turn its switch
on, grant **Mac Utils** permission in **System Settings → Privacy & Security →
Accessibility**, then retry the switch. Quit standalone strafe first if running.
Monitors and Bluetooth remain usable without this permission.

Gesture interception observes only gesture/dock-control events, not keystrokes.
The third-party source, exact upstream commit, and MIT/0BSD notices are retained
under [`Vendor/strafe`](Vendor/strafe).

## Tests and diagnostics

```sh
bash test.sh                         # isolated tests; no hardware changes
APP="build/Mac Utils.app/Contents/MacOS/MacUtils"
"$APP" --status                      # monitors
"$APP" --bluetooth-status            # paired devices; observation only
"$APP" --spaces-status               # Accessibility permission
"$APP" --restore                     # restore app-disabled monitors
```

Quit the menu app before hardware tests, which actually disable screens briefly:

```sh
"$APP" --test-cycle --name "Your Monitor Name"
"$APP" --test-multi                  # two external screens; needs a third screen
```

Hardware tests verify disable/enable, fresh-process recovery, and exact restoration
of display bounds and main-display UUID. Failure paths attempt recovery.
Undocumented display/gesture behavior may break with future macOS updates.

## License

[MIT](LICENSE). Vendored strafe retains its original [license and acknowledgments](Vendor/strafe/LICENSE).
