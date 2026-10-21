# Built-in modules and source map

Source map started at `f359f42`, with registration ownership updated through
`66056f0` and reviewed mechanical source organization integrated at `480e957`. This describes existing
code, not a completed architecture refactor. See [move evidence](validation/source-organization.md). Use
[validation](validation/README.md) for acceptance and pending release blockers.
Keep awake ownership is updated through integrated `aec5532` below.

## Modules, not a plugin system

The eleven [AppModule](../Sources/App/AppModules.swift) cases retain persisted enable-choice IDs
(`ModuleSettings`). [BuiltinFeatures.swift](../Sources/App/BuiltinFeatures.swift) registers inert
titles, descriptions, dashboard destinations, Settings order and six widget definitions;
existing enum properties delegate to that catalog without constructing owners.
Developers compile feature owners into the app through [build.sh](../build.sh).

The host in [AppDelegate.swift](../Sources/App/AppDelegate.swift) wires actions, constructs owners,
and retains activation, reconciliation, readiness and shutdown authority.
[BuiltinChoicePreparations.swift](../Sources/App/BuiltinChoicePreparations.swift) registers typed
Keep awake disable, Clipboard unload and shared Displays preparation before choice
commit. It preserves refusal/retry and does not replace admission or quit coordination.
There is no universal lifecycle/factory framework, runtime discovery or dynamic
loader. Developers adding a feature must update the catalog, host wiring, preparation,
build inputs, and tests as needed; adding an enum case alone is insufficient.

First-party app Swift lives under `Sources/`: `App/` owns entry points, composition,
setup and native host integration; `Core/` owns host transactions, readiness and
shared command execution; `SharedUI/` holds the shared Settings/widget shell,
feature configuration views and `StoredState`. `Features/<owner>/` co-locates
feature implementations: Displays, Windows, Audio, Bluetooth, Clipboard, Mouse,
Animations, MenuBar, QuitGuard and KeepAwake. Shared display geometry, refresh and
cursor recovery remain together under Displays; Windows retains its own owner/UI.
These folders are not module/package boundaries: no lifecycle extraction occurred.
`Sources/App/main.swift` remains the app/helper/CLI entry point; tests retain
`Tests/main.swift`. `Package.swift` stays at the root and explicitly owns only
`Sources/Features/Clipboard/Policy` plus its named test target. App/legacy compiler
inputs remain explicit, with policy imported and statically linked, not recompiled.
`Vendor/` contains pinned third-party engine code; `MouseHID/` contains our unchanged
C API boundary. Neither defines a user-installable plugin. See the
[partial registration contract](architecture/builtin-registration.md) and [roadmap](roadmap.md)
for the broader lifecycle work that remains proposed.

## Find the UI first

- [UISurfaces.swift](../Sources/SharedUI/UISurfaces.swift): `SettingsGroup`, six `WidgetKind` cases,
  widget editor/popup, Settings shell, and quick-action views.
- [Dashboard.swift](../Sources/SharedUI/Dashboard.swift): `DashboardModel`, `AppModule.dashboardFeature`
  mapping, shared controls, and feature configuration views. The filename predates
  the current popup/Settings split; it does not mean this is a separate plugin.
- [ActivityView.swift](../Sources/SharedUI/ActivityView.swift): the quiet General → Activity
  entry point opens a separate session-only journal; see [scope and privacy](activity.md).
- [SetupWizard.swift](../Sources/App/SetupWizard.swift): setup drafts and selected-feature
  configuration. [AppDelegate.swift](../Sources/App/AppDelegate.swift) applies Finish through host
  operations; views do not own the OS effects.

The entries below name the Settings destination and quick surface. Their shared
view implementations live in those files unless a dedicated UI file is listed.
Cleanup describes the relevant owner and path, not proof of live acceptance or a
claim that the baseline's release blockers are fixed.

## Feature owners

### Monitor switching · `monitors`

- **Owner:** [DisplayController.swift](../Sources/Features/Displays/DisplayController.swift); host helper/confirmation
  orchestration in [AppDelegate.swift](../Sources/App/AppDelegate.swift), command dispatch in [main.swift](../Sources/App/main.swift).
- **UI:** Displays settings and Displays widget. No Accessibility grant for switching.
- **Resources/cleanup:** display recovery records and confirmation timers; restore
  through the host/helper/watchdog path. The controller also serves arrangement and
  Windows; disabling one feature does not imply tearing down shared display recovery.

### Display arrangement · `arrangement`

- **Owner:** [DisplayController.swift](../Sources/Features/Displays/DisplayController.swift), geometry in
  [DisplayTopology.swift](../Sources/Features/Displays/DisplayTopology.swift), cursor mapping in [ScreenEdges.swift](../Sources/Features/Displays/ScreenEdges.swift).
- **UI:** Displays settings/widget shortcut; [DisplayArrangementEditor.swift](../Sources/Features/Displays/DisplayArrangementEditor.swift).
  Matched edges requires Accessibility; opening/editing arrangement is a separate operation.
- **Resources/cleanup:** pending-arrangement recovery, cursor event tap, editor, and
  fresh-layout state. Host disable stops cursor mapping/closes the editor; shared
  recovery remains reachable. `SystemControlLifecycle` gates cursor activation.

### Bluetooth reconnect · `bluetooth`

- **Owner:** [BluetoothModule.swift](../Sources/Features/Bluetooth/BluetoothModule.swift), including backend/policy;
  [CommandRunner.swift](../Sources/Core/CommandRunner.swift) runs external tools such as `blueutil`.
- **Observation:** [BluetoothObservation.swift](../Sources/Features/Bluetooth/BluetoothObservation.swift) compares suspicious helper reads with
  a typed read-only native snapshot; [BluetoothProfilerProcess.swift](../Sources/Features/Bluetooth/BluetoothProfilerProcess.swift)
  bounds that subprocess. Native presentation is separate from control/audio policy;
  see the [observation contract](architecture/bluetooth-observation.md).
  Blocked comparisons also collect read-only in-process controller/direct-device
  getter counts; this [qualification probe](architecture/bluetooth-qualified-control.md)
  neither connects devices nor grants native control admission. The explicit
  `--bluetooth-readonly-probe` GUI mode constructs its own inert delegate, bypassing
  normal host/module startup and cleanup rather than changing feature choices.
- **Control boundary:** native inventory is display-only. Contradictory, stale or
  incomplete comparisons block owner-level control, including queued/non-UI calls;
  native-on never triggers automatic power-on. Mutations resolve canonical saved
  IDs against the current helper's raw ID, preserve stored choices and reject
  collisions. Fresh helper reads, not native fallback, verify mutations and update
  automatic-action presentation. Typed discovery diagnostics retain helper-only
  counts/state and unknown helper authorization/source; they never grant admission.
- **UI:** Sound & connections settings, Bluetooth widget; contextual Bluetooth access.
- **Resources/cleanup:** polling timer, connection-cycle cancellation, pending manual
  and audio intents, authorization manager. `stop(completion:)` cancels work and waits
  for an in-flight cycle; post-connect routing goes to Audio rather than a second owner.

### Audio · `audio`

- **Owner:** [AudioModule.swift](../Sources/Features/Audio/AudioModule.swift), including `CoreAudioBackend`.
- **UI:** Sound & connections settings and Audio widget. Selecting a microphone does
  not record audio or require microphone-recording permission.
- **Resources/cleanup:** discovery timer, route preferences, overrides and pending
  Bluetooth intent. `stop()` clears polling/callbacks/intent. The host retains this
  owner while Bluetooth needs it, even with the Audio feature off; automatic routing
  has a separate admission flag.

### Animations · `spaces`

- **Owners:** [AnimationPreferences.swift](../Sources/Features/Animations/AnimationPreferences.swift) for system
  preference changes; [SpacesModule.swift](../Sources/Features/Animations/SpacesModule.swift) for fast Space switching.
- **UI:** System settings, with desktop switching under Advanced; no widget.
  Desktop interception requires Accessibility and watchdog/readiness checks.
- **Resources/cleanup:** preference recovery marker, Space observer, interceptor/event
  tap, and gesture queue. Preference rollback restores previous values; suspend tears
  down interception and cancels/drains gestures; full stop removes the observer.
  [Vendor/strafe](../Vendor/strafe) supplies the embedded engine, not this whole feature.

### Menu bar · `menuBar`

- **Owners:** `MenuBarModule` and `MenuBarSpacing` in [MenuBarModule.swift](../Sources/Features/MenuBar/MenuBarModule.swift).
- **UI:** System settings plus the module's chevron/divider status items; no popup widget
  or Screen Recording permission.
- **Resources/cleanup:** status items and original global spacing preferences/recovery
  state. Stop removes the hiding items and reveals icons; host spacing restoration is
  a separate path and can retain failed recovery for retry.

### Hold to quit · `quitGuard`

- **Owner/UI:** [QuitGuard.swift](../Sources/Features/QuitGuard/QuitGuard.swift) owns the input state machine and
  countdown HUD. Configuration lives in Input settings; plain ⌘Q is the quick action.
- **Permission/resources:** Accessibility; session keyboard tap/run-loop source,
  countdown polling, captured foreground identity and HUD. `stop()` cancels the hold,
  removes interception/timers and hides the HUD. Requests normal application quit.

### Keep awake · `keepAwake`

- **Owner:** [KeepAwakeFeature.swift](../Sources/Features/KeepAwake/KeepAwakeFeature.swift)
  privately owns the factory, optional [KeepAwakeModule.swift](../Sources/Features/KeepAwake/KeepAwakeModule.swift),
  callbacks and typed state/actions. The existing module still owns assertion policy,
  timers and app observation, including `SystemPowerAssertions`.
- **Presentation:** [KeepAwakePresentation.swift](../Sources/Features/KeepAwake/KeepAwakePresentation.swift)
  binds Dashboard callbacks, projects state and hosts injected app selection. System
  settings/widget views are unchanged; no TCC permission grant. Host composition
  retains admission, enabled preferences, setup sequencing, status-item coordination
  and quit authority; it no longer accesses the private KeepAwakeModule owner.
- **Resources/cleanup:** IOKit system/display assertions, deadline/update timer and
  app launch/exit observers. `deactivate()` removes observers/timer and stops reasons;
  assertion release failures have feature-owned error/cleanup state. The setup assertion
  fix is integrated; see [core evidence](validation/README.md#reviewed-core-integration--dc96e9c--2026-10-15)
  and the remaining [release gates](releases/checklist.md#native-acceptance).
- **Boundary:** feature `prepareDisable()` retains/reactivates the same owner on
  failure; actions and post-chooser selections recheck host admission. Shutdown
  keeps the existing best-effort cleanup, without adding a quit veto. See the
  [owned-feature contract and evidence](architecture/keep-awake-feature.md).

### Window positions · `windows`

- **Owner:** [WindowPositions.swift](../Sources/Features/Windows/WindowPositions.swift), including matching,
  planning and `AXWindowPositionBackend`.
- **UI:** Displays settings via [WindowPositionsView.swift](../Sources/Features/Windows/WindowPositionsView.swift);
  Window layouts widget and optional Displays restore controls. Accessibility required.
- **Resources/cleanup:** saved layout/configuration data in preferences, wake/sleep
  observers and generation-checked queued moves. `stop()` invalidates work and removes
  observers/connection registration; it keeps saved layouts. Host display settling
  gates restoration; full-screen windows and Space assignments remain outside scope.
- **Keyboard tiling:** [WindowShortcuts.swift](../Sources/Features/Windows/WindowShortcuts.swift)
  provides opt-in Rectangle-style halves, quarters, maximize, center, restore and
  display movement without another vendor. The same owner gates focused-window
  moves and unregisters Carbon shortcuts during invalidation/stop. See
  [controls, lifecycle and validation](validation/ui-window-shortcuts.md).

### Clipboard · `clipboard`

- **Owners:** [ClipboardHistory.swift](../Sources/Features/Clipboard/Policy/ClipboardHistory.swift),
  in the static `ClipboardPolicy` module, owns capture/retention
  policy and archive I/O; [ClipboardModule.swift](../Sources/Features/Clipboard/ClipboardModule.swift) owns native
  pasteboard access, shortcut registration, panel, thumbnails and presentation.
- **UI:** Clipboard settings, Clipboard widget and nonactivating ⌘⇧V panel. No
  Accessibility or Screen Recording grant for these clipboard operations.
- **Resources/cleanup:** polling/age timers, Carbon hotkey/handler, panel and memory
  entries; optional unencrypted JSON archive. Stop removes those runtime resources;
  disk retention is separate. Host unload/quit first retries pending storage work and
  can veto exit. See [privacy/defaults](#clipboard-privacy-and-retention).

### Mouse · `mouse`

- **Owners:** `MouseModule`/`MouseLifecycle` in [MouseModule.swift](../Sources/Features/Mouse/MouseModule.swift),
  [MouseSystemBackend.swift](../Sources/Features/Mouse/MouseSystemBackend.swift), and C boundary [MouseHID/MouseHID.c](../MouseHID/MouseHID.c).
- **UI:** Input settings with explicit Apply/Restore; no widget or Accessibility tap.
- **Resources/cleanup:** mouse-class IOKit runtime values and recovery JSON. Lifecycle
  startup/disable/quit paths restore originals and retain unresolved owned changes.
  Enabling does not apply tuning. The scroll-policy seam is not an installed wheel
  interceptor or a qualified physical-device classifier.

## Shared host and safety code

| File | Responsibility |
| --- | --- |
| [AppDelegate.swift](../Sources/App/AppDelegate.swift) | Feature composition, callbacks, native windows, setup application, display transactions and termination wiring. |
| [BuiltinFeatures.swift](../Sources/App/BuiltinFeatures.swift) | Inert feature/widget metadata and Settings order; no owner/view factories. |
| [BuiltinChoicePreparations.swift](../Sources/App/BuiltinChoicePreparations.swift) | Typed pre-commit choice preparation for Keep awake, Clipboard and shared Displays; host retains admission/commit/reconciliation. |
| [HostTransactions.swift](../Sources/Core/HostTransactions.swift) | Action admission and ordered quit preparation/drain/cancel/approval; feature owners still perform cleanup. See [glossary](glossary.md). |
| [ActivityJournal.swift](../Sources/Core/ActivityJournal.swift), [ActivityView.swift](../Sources/SharedUI/ActivityView.swift) | Typed, main-thread, session-only outcome history and separate native viewport; observational, not a feature/plugin or source of admission/quit authority. |
| [SystemControlLifecycle.swift](../Sources/Core/SystemControlLifecycle.swift) | Shared input/recovery readiness state and cursor reconciliation, not a general plugin lifecycle. |
| [DisplayRefreshGate.swift](../Sources/Features/Displays/DisplayRefreshGate.swift) | Coalesced display refresh/settling before input or window work resumes. |
| [SafetyWatchdog.swift](../Sources/App/SafetyWatchdog.swift), [main.swift](../Sources/App/main.swift) | Independent watchdog and helper/CLI entry paths in the same built executable. |
| [SourceUpdates.swift](../Sources/App/SourceUpdates.swift) | Source-history checks and installer launch; not feature registration or plugin updates. |

Storage has feature owners: `ModuleSettings` stores enable choices, `UISettingsStore`
in `UISurfaces.swift` stores UI/setup state, and feature files own their policy data
and recovery journals. Clipboard archives are not part of widget/setup drafts.

The host injects one in-memory Activity journal into Displays, window layouts,
Keep awake and Bluetooth outcome paths. **General → Show activity…** opens one
reusable window; no automatic opening, extra sidebar or notifications. The latest
300 entries include unfinished work; Clear affects only Activity and late results
cannot restore cleared/evicted rows. It neither reads diagnostic logs nor deletes
archives/recovery records. Native row-ID/relative-offset anchoring preserves the
reader through bursts and disclosure/width changes. See [scope, privacy and evidence](activity.md).

## Why strafe is in `Vendor/`

We reuse strafe's gesture engine/interceptor, C gesture payload code, and dependencies
instead of importing its app/hotkey/menu implementation. The import is pinned at
**`37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7`**; see
[Vendor/strafe/UPSTREAM.txt](../Vendor/strafe/UPSTREAM.txt). This is a source dependency,
not a feature-module directory, dynamic loader, or claim of full upstream app parity.

The app and vendor build uses `clang`/`swiftc` with explicit source inputs; the
Foundation-only clipboard policy is a local [Swift package](../Package.swift), linked
statically by the same bundling script. See [package commands](swiftpm.md).
Vendoring keeps that input pinned for reproducible source selection and
lets us maintain the local [SwitchEngine.swift](../Vendor/strafe/Swift/SwitchEngine.swift)
patch: cancel queued ramps, drain an active gesture before display changes/shutdown,
and inject phase posting for tests. It does not guarantee bit-for-bit builds across
different SDKs. `SpacesModule` wraps this dependency behind app-owned permission and
safety checks; the host must coordinate it with display transactions and quit.

The code carries MIT notices for strafe/InstantSpaceSwitcher and an embedded 0BSD
notice for joshuarli/iss payload work, not a GPL dependency. Preserve the complete
[vendor license and acknowledgments](../Vendor/strafe/LICENSE). The integrated build
includes complete project/vendor notices before signing; real-bundle comparisons
and strict verification passed. See [packaging validation](validation/packaging.md)
and the revision-bound [integration evidence](releases/checklist.md#current-evidence).

## Test seams and evidence

[test.sh](../test.sh) compiles native host/UI and feature code into an isolated test
executable and runs named Swift Testing suites in
[Tests/ClipboardPolicyTests](../Tests/ClipboardPolicyTests). Both use the same packaged
clipboard implementation. Feature protocols and injected factories, clocks, command runners,
presenters and persistence backends let tests exercise production actions without
performing the corresponding live OS effects.

- [Tests/main.swift](../Tests/main.swift): display/helper/watchdog, Space engine,
  Bluetooth, keep-awake, window and source-update boundaries.
- [Tests/AudioTests.swift](../Tests/AudioTests.swift), [Tests/MouseTests.swift](../Tests/MouseTests.swift):
  fake routing and HID/recovery backends.
- [Tests/ClipboardTests.swift](../Tests/ClipboardTests.swift),
  [Tests/ClipboardPresentationTests.swift](../Tests/ClipboardPresentationTests.swift):
  fake pasteboard/temp archive and panel/presentation behavior.
- [Tests/UITests.swift](../Tests/UITests.swift),
  [Tests/HostTransactionsTests.swift](../Tests/HostTransactionsTests.swift): widget/setup,
  native owned-window/action seams and host admission/quit coordination.
- [Tests/install.sh](../Tests/install.sh): mocked installer/source-update scenarios.

These seams do not establish physical-device behavior, live focus/shortcut delivery
or VoiceOver acceptance. Follow the revision-bound links in [validation](validation/README.md).

## Behavior and defaults

Fresh installations start with features off and an empty quick-action layout.
Existing installations keep their preferences. Enable features in Settings or run
guided setup; macOS permission grants survive setup cancellation.

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
dismiss without pasting. **Hold to quit:** the default is three seconds (1–99);
releasing early, switching apps, or clicking cancels. Normal quit requests preserve
save prompts; other quit commands remain unchanged.

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

## Source installation and signing

Use the [README install command](../README.md#install-from-source). The installer
keeps its checkout in `~/Library/Application Support/Fix macOS/source` and installs
to `~/Applications/Fix macOS.app`. It skips unchanged revisions only when signing
configuration and the installed signature also match. Changing the selected signing
identity triggers a rebuild; use `| bash -s -- --force` instead of `| bash` for an
unconditional rebuild. It stops rather than overwriting local source changes.

**Settings → General → Updates** checks GitHub source history on `main`, with a daily
automatic check and a manual check. Installer-managed copies offer **Install update…**
in Terminal and quit the old app before replacement. Updates follow source commits,
not release versions. The app downloads `install.sh` at the offered SHA, but that
installer fetches/builds the latest `main`; it does not guarantee the exact offered SHA.

Without a certificate, builds use ad-hoc signing; macOS may require renewed permission
grants after updates. Set `MAC_UTILS_SIGNING_IDENTITY` when running the installer to
save a local signing identity, or use `-` to persist ad-hoc signing. Unavailable or
ambiguous certificates fail closed, even at an unchanged revision. No certificate
or notarization service is included; this repository provides source installation,
not a notarized binary release.

For a manual build:

```sh
brew install blueutil switchaudio-osx
bash build.sh
open "build/Fix macOS.app"
```

Enable **Launch at login** in Settings if wanted. Run isolated developer checks
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
Development evidence includes macOS **26.6.2 (25G83)**; the macOS 15 deployment target
does not establish acceptance on every supported OS.

## Documentation and source credits

- [Current acceptance matrix and historical evidence](validation/README.md)
- [UI implementation record and remaining native acceptance](archive/ui-ux-plan.md)
- [Development roadmap and unsupported work](roadmap.md)
- [Unreleased 1.0 notes draft](releases/1.0-notes-draft.md)
- [Host admission and quit terminology](glossary.md)

[MIT](../LICENSE). Thanks to these projects and authors:

- [strafe](https://github.com/rileycx/strafe), Riley Hennigh (MIT): embedded Space-switching engine.
- [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher), jurplel (MIT): original switching technique.
- [iss](https://github.com/joshuarli/iss), joshuarli (0BSD): upstream gesture payload implementation.
- [blueutil](https://github.com/toy/blueutil) (MIT): Bluetooth control.
- [switchaudio-osx](https://github.com/deweller/switchaudio-osx), Devon Weller (MIT): audio device selection.

See [why strafe is vendored](#why-strafe-is-in-vendor) for import rationale, complete
notices, local patches, and packaging verification. Builds include the complete
project license, vendored license and upstream record under
`Contents/Resources/Licenses` before signing. Packaging verification is not
notarization evidence.
