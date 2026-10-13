# Mac Utils

One personal macOS menu-bar app for **monitors, Bluetooth, and fast desktop Space
switching**. SwiftUI dashboard in an AppKit menu-bar popover, with blue on/off switches.
Apple Silicon, macOS 15+; display toggling tested on macOS Tahoe.

> **Safety hold:** after a reported cursor-only/system input freeze, new display
> disabling and Space gesture interception are blocked pending diagnosis.
> Recovery can still enable an app-disabled display. Do not treat the isolated
> tests as proof these private-API features are safe on a live desktop.

## Build and run

Requires Xcode Command Line Tools. Bluetooth uses the same Homebrew tools as the
original auto-connect scripts:

```sh
brew install blueutil switchaudio-osx
bash build.sh
open "build/Mac Utils.app"
```

Click the sliders icon in the top menu bar. The dashboard has **Monitors**,
**Bluetooth**, and **Spaces** tabs and stays open when you toggle controls.
Blue means on, gray means off, independent of your system accent color.
Click the icon again, the close button, or outside the app to dismiss it.
**Launch at login** is optional; keep the built app at a permanent location
before enabling it.
For the affected installation, login startup has been disabled and the app left
stopped. Do not re-enable it as part of diagnosis.

## Monitors

- Every connected screen has its own switch, including the built-in screen.
- After switching off, select **Keep disabled** within 20 seconds or it restores.
- Disabled screens remain listed. The last usable screen cannot be disabled.
- **Enable all disabled displays**, quitting, or relaunching after a crash restores
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

- Open the **Bluetooth** tab and turn on the switch beside each device you want
  to **reconnect automatically**. These switches select reconnect rules; they do
  not represent whether a device is connected right now.
- The global **Automatic reconnection** switch starts/pauses the selected rules.
  Pausing preserves selections. An empty selection explicitly asks you to choose
  devices. Only selected devices are actively reconnected; idle headphones are
  not probed.
- Each row separately shows **Connected / Disconnected**, with a one-time
  **Connect / Disconnect** button. Disconnecting an automatically reconnected
  device asks for confirmation before disabling its reconnect rule. No manual
  connection action silently rewrites your selected rules.
- **Advanced headphone detection** marks known audio devices to protect even
  before macOS registers their audio output.
- Bluetooth commands run on a background queue, with timeouts—not on the UI thread.
- By default, other connected Bluetooth audio devices pause reconnection. Audio
  is checked again after connecting before switching the output, protecting
  headphones that arrived during the connection attempt.
- Keyboards do not block reconnecting audio when audio-output discovery is
  available. Without that discovery, any other connected Bluetooth device blocks
  automatic reconnection conservatively.
- Auto-connect runs only while Mac Utils is running, checking every five seconds.
- Device addresses and preferences stay in local UserDefaults. No telemetry.

### Migrating the previous Bluetooth tool

The app can import the speaker selection from the old `smart-connect.sh` under
`~/Projects/others/bluetooth-connect/bluetooth-connect/`. It never edits that script.

If `com.user.bluetooth-autoconnect` is installed, Mac Utils leaves its reconnect
loop in charge until **Bluetooth → Take over existing service…** is
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

Hardware tests are currently blocked by the safety hold. When the private-API
behavior has been diagnosed and verified, these commands exercise real displays:

```sh
"$APP" --test-cycle --name "Your Monitor Name"
"$APP" --test-multi                  # two external screens; needs a third screen
```

Hardware tests verify disable/enable, fresh-process recovery, and exact restoration
of display bounds and main-display UUID. Failure paths attempt recovery.
Undocumented display/gesture behavior may break with future macOS updates.

## License

[MIT](LICENSE). Vendored strafe retains its original [license and acknowledgments](Vendor/strafe/LICENSE).
