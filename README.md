# Fix macOS

One personal macOS menu-bar app for **monitors, Bluetooth, and fast desktop Space
switching**. SwiftUI dashboard in an AppKit menu-bar popover, with blue on/off switches.
Apple Silicon, macOS 15+; display toggling tested on macOS Tahoe.

> Monitor and Space controls are available when the independent watchdog is ready.
> Gesture interception starts off and pauses whenever displays change. The earlier
> system freeze remains unexplained; upstream parity and isolated tests do not prove
> live WindowServer safety. See [upstream validation](VALIDATION.md).

## Build and run

Requires Xcode Command Line Tools. Bluetooth uses the same Homebrew tools as the
original auto-connect scripts:

```sh
brew install blueutil switchaudio-osx
bash build.sh
open "build/Fix macOS.app"
```

Click the sliders icon in the top menu bar. The dashboard has **Monitors**,
**Bluetooth**, and **Spaces** tabs and stays open when you toggle controls.
Blue means on, gray means off, independent of your system accent color.
Click the icon again, the close button, or outside the app to dismiss it.
**Launch at login** is optional; keep the built app at a permanent location
before enabling it.
For the affected installation, login startup has been disabled and the app left
off at login. The guarded build can be launched manually; enable Space interception
explicitly in the dashboard after granting Accessibility permission.

### Recovery safeguards

- A separate, Foundation-only watchdog checks a main-run-loop heartbeat. After
  an eight-second UI stall it terminates **only its own parent app** and records
  the incident. It does not restart the app or Mac, or kill Dock/WindowServer.
- An unclean previous session is recorded. Gesture interception never auto-starts.
- Display notifications are deferred until a 1.5-second quiet period and bursts
  are coalesced. Their callbacks perform no graphics queries. Bluetooth polling
  updates only Bluetooth state, never display state.
- Any explicit display recovery runs in a separate, time-limited process. The
  watchdog attempts recovery only if app-disabled displays are recorded.
- The popup dismisses normally outside the app or with Escape; no global input
  monitor is used by the dashboard.
- Every manual Bluetooth disconnect requires confirmation, including a warning
  about keyboard/mouse access. Selected reconnect rules change only with consent.

The watchdog cannot guarantee recovery from a stalled macOS graphics driver or
WindowServer. The live incident's root cause has not yet been confirmed.

## Monitors

- Every connected screen has its own switch, including the built-in screen.
- After switching off, select **Keep disabled** within 20 seconds or it restores.
- Display transactions run in a bounded helper process, not on the UI thread.
  Only one unconfirmed change is allowed at a time. Space interception pauses
  before display transactions and after hotplug notifications.
- Disabled screens remain listed. The last usable screen cannot be disabled.
- **Enable all disabled displays** or quitting restores the screens this app
  disabled. After relaunching, use explicit recovery for any recorded disabled screens.
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

**First grant macOS Bluetooth access to Fix macOS.** Use **Allow Bluetooth
access…** in the dashboard, or **System Settings → Privacy & Security → Bluetooth**.
Terminal permission is not app permission: terminal diagnostics can succeed while
the GUI is denied. The app now distinguishes permission denial from radio power.

By default, local builds are ad-hoc signed; recompiling changes their code hash
and may invalidate an existing permission grant. After the final build, grant
access again. For stable identity across updates, optionally use a legitimate
installed signing identity:

```sh
MAC_UTILS_SIGNING_IDENTITY="Your Apple Development signing identity" bash build.sh
```

To retain that identity for subsequent builds in this clone:

```sh
git config --local macutils.signingIdentity "Your Apple Development signing identity"
bash build.sh
```

This setting stays in local Git configuration. A configured signing failure stops
the build rather than silently switching back to ad-hoc signing. When migrating
from ad-hoc signing, remove the old app entry from **Privacy & Security →
Accessibility**, then add `build/Fix macOS.app` again and enable it. Merely toggling
an old entry may retain its stale code requirement. Restart the app afterward.

Signing keys remain in Keychain and are not exported or committed. Fix macOS
does not edit the TCC database or grant itself permissions.

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
- A failed target does not stop attempts for other selected devices. Failed
  devices back off for 30 seconds. Connection attempts allow up to 35 seconds,
  long enough for macOS's normal Bluetooth page timeout.
- Connect/Disconnect requests are queued during discovery instead of discarded.
  Manual requests take priority over later auto-connect targets. An already
  in-flight OS connection may finish before the queued request starts.
- Radio-off, connecting, unavailable-device errors, and audio-priority waits are
  visible in the dashboard. **Turn Bluetooth on** enables the radio explicitly;
  the app never powers it off automatically.
- By default, other connected Bluetooth audio devices pause reconnection. Audio
  is checked again after connecting before switching the output, protecting
  headphones that arrived during the connection attempt.
- Keyboards do not block reconnecting audio when audio-output discovery is
  available. Without that discovery, any other connected Bluetooth device blocks
  automatic reconnection conservatively.
- Auto-connect runs only while Fix macOS is running, checking every five seconds.
- Device addresses and preferences stay in local UserDefaults. No telemetry.

### Migrating the previous Bluetooth tool

The app can import the speaker selection from the old `smart-connect.sh` under
`~/Projects/others/bluetooth-connect/bluetooth-connect/`. It never edits that script.

If `com.user.bluetooth-autoconnect` is installed, Fix macOS leaves its reconnect
loop in charge until **Bluetooth → Take over existing service…** is
confirmed. This stops/disables the old LaunchAgent and enables Fix macOS's loop.
Its script and plist remain intact. Enable **Launch at login** if wanted.

## Desktop Spaces

Embeds the gesture engine/interceptor from [strafe](https://github.com/rileycx/strafe)
in the same app—no second strafe process or menu icon. **Fast Space switching**
supports Instant, Quick and Smooth speeds. This affects trackpad Space-switching
transitions, **not all macOS animations**. It does not include strafe's keyboard
shortcuts or standalone CLI.

Accessibility permission is required **only** for this feature. Turn its switch
on, grant **Fix macOS** permission in **System Settings → Privacy & Security →
Accessibility**, then retry the switch. Quit standalone strafe first if running.
Monitors and Bluetooth remain usable without this permission.

Gesture interception observes only gesture/dock-control events, not keystrokes.
The third-party source, exact upstream commit, and MIT/0BSD notices are retained
under [`Vendor/strafe`](Vendor/strafe).

## Tests and diagnostics

```sh
bash test.sh                         # isolated tests; no hardware changes
APP="build/Fix macOS.app/Contents/MacOS/fix-mac-os"
"$APP" --status                      # monitors
"$APP" --bluetooth-status            # paired devices; observation only
"$APP" --bluetooth-app-status        # actual running GUI snapshot and errors
"$APP" --spaces-status               # Accessibility permission
"$APP" --restore                     # restore app-disabled monitors
```

Real Bluetooth-module test, using a paired device that is powered on and nearby:

```sh
"$APP" --test-bluetooth-connect "Your Audio Device Name"
# Optional controlled disconnect/reconnect; restricted to recognized audio devices:
"$APP" --test-bluetooth-connect "Your Audio Device Name" --cycle
```

Quit the GUI before this test to avoid competing reconnect loops. It exercises
the dashboard's queued connection action, verifies the real connected state,
preserves reconnect selections, and restores the original audio output if macOS
automatically changed it. It never disconnects input devices. Running GUI
diagnostics contain device names and remain in local preferences, not the repo.

The legacy `--test-cycle` and `--test-multi` commands remain blocked because they
do not run under the GUI watchdog. For a supervised hardware check, use one monitor
switch in the dashboard and let its 20-second confirmation expire; verify that
the original monitor arrangement returns before keeping a subsequent change.
Undocumented display/gesture behavior may break with future macOS updates.

## License

[MIT](LICENSE). Vendored strafe retains its original [license and acknowledgments](Vendor/strafe/LICENSE).
