# Fix macOS

A macOS menu-bar app for managing monitors, Bluetooth connections, and desktop switching.

## Features

- **Monitor switching:** turn individual screens on or off. Choose **Dangerously** (default, immediate) or **Safely** (20-second undo); both keep at least one usable display active.
- **Display arrangement:** drag screens into place, preview changes, and close gaps when a monitor goes off. **Match screen edges** maps cursor crossings between differently sized screens, using the full shared edge.
- **Bluetooth reconnect:** choose devices to reconnect, connect or disconnect on demand, and protect other audio connections.
- **Animations:** limit Dock, Finder, window, and scrolling effects; replace Genie minimization with Scale and try experimental tiling-animation suppression. Fast desktop switching lives under Advanced. Turning the preset off restores your previous settings. Effects vary by app; Mission Control and Control Center may still animate.
- **Menu bar:** experimental compact spacing and a movable divider for hiding extra icons. Both controls start off. ⌘-drag the divider left of the chevron, and less-used icons left of the divider. Click the chevron to hide/reveal them; quitting reveals them. Spacing changes may require restarting apps or logging out; turning spacing or the module off restores original values. This is not a separate overflow panel for icons behind the notch.
- **Hold to quit:** under **Keyboard**, hold ⌘Q for 3 seconds by default, adjustable from 1 to 99 seconds. A popup names the app while Pac-Man eats dots across the countdown. Releasing early, switching apps, or clicking cancels. Uses normal quit requests, preserving save prompts. Requires Accessibility access; starts off. Menu commands and other quit shortcuts are unaffected.
- **Keep awake:** timed presets, five-minute custom increments, +15 minutes, and optional display wake. Add apps by bundle identity to stay awake while they run in the background. Timed and app reasons overlap; Stop pauses currently matching apps until they exit, and Resume restores them. Disabling the module releases assertions; timed sessions never survive relaunch. Saved app rules apply to already-running apps on activation.

Enable or disable each module from the **gear icon**. Disabled modules stop background work and release their state; your settings stay saved.

## Install from source

Requires Apple Silicon, macOS 15+, Xcode Command Line Tools (`xcode-select --install`), and [Homebrew](https://brew.sh).

```sh
curl -fsSL https://raw.githubusercontent.com/jakub-tucek/fix-mac-os/main/install.sh | bash
```

The installer installs the Bluetooth dependencies, keeps its source checkout in
`~/Library/Application Support/Fix macOS/source`, and installs to
`~/Applications/Fix macOS.app`. Rerun the command to update; unchanged revisions
skip rebuilding. Add `| bash -s -- --force` instead of `| bash` to force a rebuild.
Local checkout changes are preserved: the installer stops rather than overwriting them.

The app checks GitHub for source changes daily. **Settings → Updates** offers a
manual check and, for installer-managed copies, **Install update…**. Updates build
from source in Terminal and quit the old app normally before replacing it.

Without a signing certificate, builds use ad-hoc signing and macOS may ask you to
grant permissions again after updates. Set `MAC_UTILS_SIGNING_IDENTITY` when running
the installer to retain your signing identity in its local Git configuration.

## Build manually

```sh
brew install blueutil switchaudio-osx
bash build.sh
open "build/Fix macOS.app"
```

Grant Bluetooth access for device management and Accessibility access for trackpad switching. Enable **Launch at login** if you want it to start with your Mac.

Display changes last for the current login session. Display and gesture features use private macOS APIs; see the [validation notes](VALIDATION.md) for known limitations.

Run the isolated checks with `bash test.sh`.

## Implementation roadmap

Implement independent modules in parallel in separate worktrees. Within each module,
complete its increments in order. Each checkbox represents a usable increment with
UI, saved preferences where needed, and verification. The items below are planned.

### 1. Keep awake

- [ ] **1A · Timed sessions.** Add a **Keep awake** module with 30-minute and
  1-hour presets, a remaining-time display, and Stop. Use IOKit power assertions.
  Keep the computer awake while allowing the display to sleep; offer a separate
  **Keep display awake** switch. Release assertions on expiry, Stop, module disable,
  and app exit. After relaunch, start idle and retain the user's preferences.
  **Done when:** verify assertions with `pmset -g assertions`; test expiry and cleanup,
  including a session whose deadline passes during sleep.
- [ ] **1B · App-based sessions.** Let the user choose apps that keep the Mac awake
  while running, including in the background. Match bundle identifiers across
  launches. Show which app keeps the session active. Combine timed and app-based
  reasons without ending a session while another reason still applies. Stop pauses
  the current app-based session until the matching apps exit; provide Resume.
  **Done when:** test apps already running at startup, launch/exit events, overlapping
  reasons, and module disable. Respect explicit Sleep and normal lid-close behavior.

### 2. Preferred audio devices

Build on the existing Bluetooth connection protection and post-connect output
switching. Keep Bluetooth reconnect rules separate from audio-routing preferences.

- [ ] **2A · Device selection.** Add an **Audio** module with current input/output,
  manual selection, and separate preferred-device lists for microphone and output.
  Identify audio devices by stable UID rather than display name. Include built-in,
  Bluetooth, USB, and monitor audio; share discovery and routing with Bluetooth.
  **Done when:** test duplicate names, missing devices, and reconnected devices;
  manual switching changes only the selected input or output.
- [ ] **2B · Routing rules.** On device arrival/removal, choose the highest available
  preference. Offer an explicit fallback and preserve the user's current route when
  none matches. Let users keep the built-in microphone while using headphone output.
  Retain existing protections for connected headphones and respect manual overrides
  until the next relevant device change or explicit Resume.
  **Done when:** test headset reconnect, USB unplug, monitor wake, and manual override;
  Bluetooth and Audio must not compete to change the output.

### 3. Restore window positions

The **Windows** dashboard implements both iterations below with opt-in automation.
See [window-position validation](WINDOW-POSITIONS-VALIDATION.md) for isolated evidence
and remaining live/hardware acceptance checks; roadmap boxes remain open until those checks pass.

- [ ] **3A · Save and restore on demand.** Add a **Window positions** module using
  Accessibility APIs. Save a named layout for the current display set, with display
  identities, window frames, and app/window matching information. Provide **Restore
  now** with a result summary. Keep restored windows within available screen bounds.
  **Done when:** restore windows from several apps after moving/resizing them; report
  missing, ambiguous, and unsupported windows instead of moving a guessed match.
- [ ] **3B · Restore after reconnect or wake.** Reuse display-settling coordination
  and select a saved layout for the connected display set. Wait for monitor changes
  and confirmations to finish; cancel stale queued restores. Preserve saved layouts
  when a display disappears. Add Pause and per-app exclusions. Initially restore
  ordinary windows accessible on the current desktop; leave full-screen windows
  and Space assignments alone.
  **Done when:** exercise unplug/replug, wake, and A–B–C → A–C → A–B–C; verify that
  repeated display notifications do not keep moving windows after restoration.

### 4. Mouse controls

- [ ] **4A · Acceleration and speed.** First verify which mouse-only controls work
  on the target macOS version. Add a **Mouse** module with acceleration control and
  tracking speed for supported hardware. Capture original settings before changes
  and restore them on disable. State whether each control applies to all mice or
  an individual device.
  **Done when:** test a physical mouse alongside the trackpad, reconnect the mouse,
  and verify restoration. Trackpad movement must retain its current behavior.
- [ ] **4B · Separate scrolling.** Offer traditional mouse scrolling while keeping
  natural trackpad scrolling. Establish reliable input-device identification first,
  then add direction and speed controls. Pass through events whose source cannot
  be identified, and stop interception when the module turns off.
  **Done when:** test a wheel mouse, trackpad momentum, horizontal scrolling, and
  modifier-assisted scrolling without duplicate or dropped events.

### 5. Clipboard history

- [ ] **5A · Local text history.** Add a **Clipboard** module with the latest 100
  distinct text entries, search, a keyboard shortcut, and click/Return to copy an
  entry back to the clipboard. Start with memory-only history and a per-entry size
  limit. Provide Pause, Clear, per-entry Delete, and app exclusions. Skip clipboard
  formats marked concealed or transient; prevent recapture loops after history selection.
  **Done when:** test repeated copies, large text, exclusions, rapid clipboard changes,
  and module disable. History selection must preserve focus in the destination app.
- [ ] **5B · Retention and richer entries.** Add opt-in disk history with an age limit,
  pinned entries, then images with a separate storage cap. Keep excluded/marked
  content out of persistence and remove expired content on startup as well as during use.
  **Done when:** verify restart, expiry, storage limits, and Clear against both memory
  and disk, including image files.

### Iteration checklist

- Use the existing lazy-module lifecycle and right-aligned switches. Keep settings
  when a module turns off; release its timers, observers, assertions, and event taps.
- Give shared OS controls one owner, especially audio routing and display recovery.
- Test policy with fake backends; validate OS effects on this Mac and record results
  and remaining limitations in [VALIDATION.md](VALIDATION.md).
- Run `bash test.sh` and `git diff --check`, then commit each module's increment.
  Have an independent reviewer check it, address findings in a separate commit,
  and repeat review and tests until actionable findings are resolved.
- Integrate reviewed commits one module at a time. Recheck shared UI, module shutdown,
  audio ownership, and display coordination after integration. Update checkboxes
  after verification; record physical-device checks that remain outstanding.

**Keep-awake implementation:** 1A and 1B are implemented. Checkboxes remain pending physical sleep/lid-close and interactive UI verification; see [keep-awake validation](AWAKE-VALIDATION.md).

**In progress:** Audio, Window positions, Mouse, and Clipboard.

## Credits

Thanks to these MIT-licensed projects and their authors:

- [strafe](https://github.com/rileycx/strafe) by Riley Hennigh: the embedded Space-switching engine.
- [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) by jurplel: the original instant-switching technique behind strafe.
- [blueutil](https://github.com/toy/blueutil): Bluetooth device control.
- [switchaudio-osx](https://github.com/deweller/switchaudio-osx) by Devon Weller: audio-output selection.

## License

[MIT](LICENSE). Upstream notices remain in [Vendor/strafe/LICENSE](Vendor/strafe/LICENSE).
