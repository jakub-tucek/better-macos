# Monitor Toggle

A small native **Swift/AppKit** macOS menu-bar app. Lists connected displays,
including the built-in screen, with a checked on/off toggle for each. No paid app
or runtime dependencies. Apple Silicon, macOS 13+; tested on macOS Tahoe.

## Build and run

Requires Xcode Command Line Tools.

```sh
bash build.sh
open "build/Monitor Toggle.app"
```

Click the monitor icon in the top menu bar, then a monitor name to toggle it.
Checked means enabled. After disabling, click **Keep … disabled** within 20 seconds
or it automatically reconnects. Disabled monitors stay in the list.

- **Enable all disabled monitors** restores every screen disabled by this app.
- **Quit** restores screens before exiting. Relaunching recovers an interrupted run.
- **Launch at login** is optional; keep the app at a permanent path first.
- The last usable screen cannot be disabled. Disable mirroring before using toggles.

Original desktop positions and main-display status are restored once every
app-disabled screen is back, provided the connected setup has not changed.
Resolution, brightness and color profiles are not changed.

## Diagnostics and hardware regression tests

Quit the menu-bar app before running hardware tests to avoid concurrent changes.

```sh
APP="build/Monitor Toggle.app/Contents/MacOS/MonitorToggle"
"$APP" --status
"$APP" --snapshot
"$APP" --restore
# Actually disables this monitor briefly, then restores it:
"$APP" --test-cycle --name "Dell S2716DG"
# Disables two external monitors, then restores both. Needs a third active screen:
"$APP" --test-multi
```

Tests verify disabling, recovery from a fresh process, and exact restoration of
display bounds and main-display UUID. All test failure paths attempt recovery.

## Implementation and limitations

Uses the undocumented `CGSConfigureDisplayEnabled` API loaded dynamically from
SkyLight. Future macOS releases may break it; failures are shown rather than
silently falling back to dimming or mirroring. This removes a screen from the
desktop; it does not physically power off the monitor.

Changes are session-only: logout/reboot resets them, even after an app crash.
On Tahoe, disabled screens disappear from UUID lookup. Recovery uses their
pre-disable IDs, restricted to the same boot and rejected if reassigned to a
different visible monitor. Plugging/unplugging or restarting WindowServer while
screens are disabled can prevent recovery; logout is the fallback.

Displays are identified by UUID, not name, so identically named monitors have
independent toggles. Mirror slaves may appear with a generic name.
No administrator or Accessibility permissions required.
