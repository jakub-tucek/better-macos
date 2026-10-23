# Using Fix macOS

[Overview and install command](../README.md) · [All documentation](README.md)

Current behavior checked against `1434620` on 2026-10-23. These are usage
instructions, not a new live acceptance run. [Known validation gaps](validation/README.md).

## Start here

Fresh installations start with features off and an empty quick-action layout.
Existing installations keep their preferences.

1. Open **Settings** from the menu-bar popup or right-click menu.
2. Enable only the features you want, or use **General → Run setup again**.
3. Grant macOS access when a chosen feature needs it.
4. Use **Quick actions** to add everyday controls to the popup.

Enabling a feature and showing its widget are separate choices. Removing a widget
does not disable the feature, stop its session, or delete its data. Disabled
features stop their feature work, but shared services and pending recovery can
remain loaded until their work is safe.

## Find the controls

| Surface | Use it for |
| --- | --- |
| Left-click menu-bar icon | Your chosen quick-action widgets |
| Right-click menu-bar icon | Window actions, Quick actions, Keep awake, Settings, Quit |
| Window actions palette | Illustrated window layouts and display movement |
| Keep awake palette | Duration presets, custom duration, display wake, extension, End session |
| Settings | Configuration in seven tabs; reused rather than opening another window |
| Clipboard panel · ⌘⇧V | Search, select, copy, pin, and delete history entries |
| General → Show activity… | Session-only operation outcomes, not technical logs |

Use arrows to choose a window action or awake-duration preset, Return/Space to
apply, and Escape to close. Window actions also supports Tab/Shift-Tab selection.
Opening or dismissing a palette does not move a window or change an awake session.
Window actions target the captured foreground window; changed focus or displays
can refuse an action rather than redirect it.

### Settings and setup

| Settings tab | Contents |
| --- | --- |
| General | Launch at login, source updates, Activity, repeat setup |
| Quick actions | Widget choices, order, compact/expanded presentation |
| Displays | Monitor switching, arrangement, matched edges, window layouts and shortcuts |
| Sound & connections | Output/microphone preferences, Bluetooth targets and protection |
| Input | Hold to quit and explicit Mouse Apply/Restore |
| System | Animations, menu-bar controls, Keep awake defaults/app rules |
| Clipboard | Capture, exclusions, retention, privacy, storage recovery |

Popup **Edit** supports Add, ordering, compact/expanded presentation, Remove, and
Restore suggested. **Done** saves; **Cancel** discards the draft. Recovery controls
and an active awake session's Stop remain reachable without widgets. Clipboard
widgets never preview copied content.

Setup starts from current choices. Only **Finish** applies configuration; Cancel
discards drafts, not macOS permission grants. Setup does not move windows, rearrange
displays, apply Mouse tuning, or start timed awake sessions. Enabling features can
start reviewed app-awake rules, Bluetooth reconnect, or automatic audio routing;
animation changes may restart Dock/Finder. Finish reports per-feature outcomes
and pending access/hardware. Mouse still requires explicit **Apply**.

## Window shortcuts

Enable **Displays → Window positions → Window keyboard shortcuts**. Shortcuts
default off and need Accessibility plus host/display readiness. Rectangle is not
required; these are first-party controls using a Rectangle-style preset.

| Keys | Action |
| --- | --- |
| ⌃⌥ ← / → / ↑ / ↓ | Left / right / top / bottom half |
| ⌃⌥ U / I / J / K | Top left / top right / bottom left / bottom right |
| ⌃⌥ D / F / G | First / middle / last third |
| ⌃⌥ E / T | First / last two-thirds |
| ⌃⌥ Return | Maximize within usable display bounds |
| ⌃⌥ M | Almost maximize, with a five-percent inset on each side |
| ⌃⌥ C | Center |
| ⌃⌥ Delete | Restore original session frame |
| ⌃⌥⌘ ← / → | Previous / next display in spatial order, wrapping at the ends |
| ⌃⌥⌘ Space | Open Window actions |

⌃ = Control, ⌥ = Option, ⌘ = Command. Letter shortcuts use US physical key
positions. The popup, Windows widget, and right-click menu can open Window actions
even when global window shortcuts are off.

Repeated **Left half** traverses: current left → neighboring right → neighboring
left → next neighboring right. **Right half** mirrors this. Crossing requires the
window to match the requested half exactly; the outermost display stops rather
than wrapping. Separate Previous/Next display actions still wrap.

Registration is all-or-nothing. If another app owns a key, quit the conflicting
window manager and use **Retry**. Original frames are retained for up to 64 windows
in the loaded feature session, shared by palette and keyboard actions. Stopping
the feature discards them; saved named layouts remain.

Only ordinary accessible windows on the current Space are supported. App minimum
sizes, missing AX metadata, exclusions, focus changes, or ambiguous identity can
refuse a move. A failed write can leave a partly moved/resized window. No drag
snapping, custom bindings, full-screen control, or Space assignments are provided.

## Behavior and defaults

- **Displays:** default **Dangerously** mode acts immediately; **Safely** offers a
  20-second undo for disabling. Both protect the last usable display. Arrangement
  changes require confirmation; changes last for the login session. Recovery does
  not depend on a ready watchdog, but new display disabling does.
- **Saved window layouts:** named layouts are stored in preferences, including
  window titles. Automatic wake/reconnect restoration defaults off. Missing,
  ambiguous, excluded, unsupported, and failed windows are reported separately.
- **Audio:** automatic routing starts off and polls device changes every two
  seconds. Manual changes pause that direction until a device-list change or Resume.
- **Bluetooth:** choose paired targets in Sound & connections. Native macOS
  inventory can be shown when helper reads disagree, but cannot authorize a
  connection, route audio, or automatically power on the radio. Conflicting,
  stale, or incomplete comparisons block control. The read-only native probe is
  diagnostic infrastructure, not a reconnect fix or control fallback.
- **Keep awake:** custom durations accept 1–1440 whole minutes, with presets and
  +15 minutes. Stop/End session pauses matching app reasons; Resume restores them.
  Ending permits normal sleep, not immediate sleep. Timed sessions do not survive
  relaunch. Lid-closed operation is not promised.
- **Clipboard:** select an entry, then press Return or click **Copy** to copy and
  dismiss without pasting. Capture starts paused each launch; see privacy below.
- **Hold to quit:** default three seconds, configurable from 1–99. Releasing early,
  switching apps, or clicking cancels. It requests normal quit, preserving save
  prompts; other quit commands remain unchanged.
- **Mouse:** Apply changes mouse-class IOKit runtime values, not system preferences.
  Disable/quit restores captured values. Relaunch/reconnect does not reapply
  overrides. Readback verifies API results, not physical effectiveness. No per-device
  or wheel controls.
- **Animations:** turning the preset off restores prior settings. Effects vary by
  app and do not suppress all Mission Control/Control Center motion. Fast desktop
  switching targets horizontal Space gestures, not the Mission Control overview.
- **Menu bar:** spacing and hiding start off. ⌘-drag the divider left of the chevron
  and extra icons left of the divider. Click the chevron to hide/reveal; quitting
  reveals icons. Spacing may require app relaunch/logout. No notch-overflow panel.

## Clipboard privacy and retention

Capture starts **paused each launch**. History defaults to memory-only, with at most
100 entries, UTF-8 text up to **64 KiB**, and **PNG only**, up to **4 MiB per image**
and **32 MiB total image bytes**. Pins bypass age expiry, not hard caps.

Optional disk retention stores an **unencrypted JSON archive**, including image
bytes, at `~/Library/Application Support/Fix macOS/Clipboard/history.json`. Choose
1–365 days for unpinned entries.

| Action | Effect |
| --- | --- |
| Pause capture | Stop collecting new copies; retain history |
| Turn the Clipboard feature off | Stop runtime work; keep retention choice and archive |
| Turn disk retention off | Delete the archive; keep in-memory history |
| Clear history | Delete history, including pins; leave current clipboard and capture/retention intent unchanged |

Failed storage or cleanup stays pending with retry and can block feature unload
or quit. Force quit/crash during a filesystem failure can leave the last successfully
written archive. Capture, retention, and deletion are separate choices.

The app samples the clipboard every **500 ms** and can miss intermediate copies.
App exclusions use the foreground app at sampling time, not proven clipboard
authorship. Concealed, transient, and autogenerated formats are skipped. These
filters cannot guarantee that other apps label sensitive content correctly.

Activity is memory-only and excludes clipboard contents. Technical diagnostics
stay local and use restricted fields; they are separate from Clipboard history.
See [Activity privacy](activity.md#history-and-privacy) and [diagnostics](diagnostics.md).

## Source installation and signing

Use the [README install command](../README.md#install-from-source). The installer
requires Apple Silicon/macOS 15+, Command Line Tools, Git, and Homebrew. Only the
[recorded compiler/SDK combinations](development.md#host-and-compiler) have been
validated; the deployment target does not prove older tools can build the app.

The installer keeps its checkout in
`~/Library/Application Support/Fix macOS/source`, installs `blueutil` and
`switchaudio-osx`, and builds `~/Applications/Fix macOS.app`. It normally opens the
app. Updating requests normal quit and waits before replacement; a busy app can
refuse. It stops rather than overwriting local source changes or local commits.

For the streamed install command, replace `| bash` with:

- `| bash -s -- --force` for an unconditional rebuild.
- `| bash -s -- --no-open` to avoid opening the app afterward. This does **not**
  suppress normal quit of an already-running app during replacement.

Unchanged revisions are skipped only when signing configuration and the installed
signature also match. Changing the selected signing identity triggers a rebuild.

**Settings → General → Updates** checks GitHub source history on `main`, with a daily
automatic check and a manual check. Installer-managed copies offer **Install update…**
in Terminal. Updates follow source commits, not release versions. The app downloads
`install.sh` at the offered SHA, but that installer fetches/builds latest `main`;
it does not guarantee the exact offered SHA.

Without a certificate, builds use ad-hoc signing; macOS may require renewed permission
grants after updates. Set `MAC_UTILS_SIGNING_IDENTITY` in the installer's environment
to save a local signing identity, or use `-` to persist ad-hoc signing. Unavailable or
ambiguous certificates fail closed, even at an unchanged revision. No certificate
or notarization service is included. This is source installation, not a notarized
binary release.

For a manual build from a checkout:

```sh
brew install blueutil switchaudio-osx
bash build.sh
```

Build/signing does not launch the app. When ready to run it:

```sh
open "build/Fix macOS.app"
```

Enable **Launch at login** in General if wanted. Its switch represents registration
intent, including pending system approval, not proof of a successful next-login launch.
Run developer checks with [these commands](development.md#commands).

## Permissions and limits

- **Accessibility:** desktop switching, matched screen edges, Hold to quit, window
  capture/restore, and window tiling. Grant access for the features you use.
- **Bluetooth:** contextual authorization for device management. Parent app access
  does not independently prove external helper access.
- **Microphone / Screen Recording:** selecting an audio input does not record it.
  Production features need neither microphone-recording nor Screen Recording access.

Display and gesture features use private macOS APIs. The watchdog cannot guarantee
recovery from a stalled WindowServer or graphics driver. Physical monitor recovery,
trackpad behavior, mouse effectiveness, audio hardware, and live accessibility/focus
checks still have acceptance gaps. Development evidence includes macOS **26.6.2
(25G83)**; the macOS 15 deployment target does not establish acceptance on every
supported OS. [Evidence and open gates](validation/README.md).
