# Built-in modules and source map

Source baseline: `f359f42`; documentation follow-up to `8c96b83`. This map describes
the existing code, not a completed architecture refactor. Use
[VALIDATION.md](VALIDATION.md) for acceptance and pending release blockers.

## Modules, not a plugin system

The eleven [AppModule](AppModules.swift) cases identify built-in features, titles,
descriptions, and persisted enable choices (`ModuleSettings`). They are not plugin
implementations or a registration interface. Developers compile the feature owners
into the app process through the explicit file list in [build.sh](build.sh).

The host in [AppDelegate.swift](AppDelegate.swift) wires actions, constructs owners,
and handles activation, disable, readiness, and shutdown by hand. There is no common
module lifecycle protocol, unified plugin registry, runtime discovery, or dynamic
loader. Developers adding a feature must update host wiring, settings/navigation,
build inputs, and tests as needed; adding an enum case alone is insufficient.

Most first-party Swift files remain at the repository root. This flat layout is
organizational debt, not a hidden plugin-folder convention. `Vendor/` contains
third-party engine code; `MouseHID/` contains our C API boundary; neither directory
defines a user-installable plugin. Future registration/layout work belongs in the
[roadmap](ROADMAP.md), not in descriptions of current capabilities.

## Find the UI first

- [UISurfaces.swift](UISurfaces.swift): `SettingsGroup`, six `WidgetKind` cases,
  widget editor/popup, Settings shell, and quick-action views.
- [Dashboard.swift](Dashboard.swift): `DashboardModel`, `AppModule.dashboardFeature`
  mapping, shared controls, and feature configuration views. The filename predates
  the current popup/Settings split; it does not mean this is a separate plugin.
- [SetupWizard.swift](SetupWizard.swift): setup drafts and selected-feature
  configuration. [AppDelegate.swift](AppDelegate.swift) applies Finish through host
  operations; views do not own the OS effects.

The entries below name the Settings destination and quick surface. Their shared
view implementations live in those files unless a dedicated UI file is listed.
Cleanup describes the relevant owner and path, not proof of live acceptance or a
claim that the baseline's release blockers are fixed.

## Feature owners

### Monitor switching · `monitors`

- **Owner:** [DisplayController.swift](DisplayController.swift); host helper/confirmation
  orchestration in [AppDelegate.swift](AppDelegate.swift), command dispatch in [main.swift](main.swift).
- **UI:** Displays settings and Displays widget. No Accessibility grant for switching.
- **Resources/cleanup:** display recovery records and confirmation timers; restore
  through the host/helper/watchdog path. The controller also serves arrangement and
  Windows; disabling one feature does not imply tearing down shared display recovery.

### Display arrangement · `arrangement`

- **Owner:** [DisplayController.swift](DisplayController.swift), geometry in
  [DisplayTopology.swift](DisplayTopology.swift), cursor mapping in [ScreenEdges.swift](ScreenEdges.swift).
- **UI:** Displays settings/widget shortcut; [DisplayArrangementEditor.swift](DisplayArrangementEditor.swift).
  Matched edges requires Accessibility; opening/editing arrangement is a separate operation.
- **Resources/cleanup:** pending-arrangement recovery, cursor event tap, editor, and
  fresh-layout state. Host disable stops cursor mapping/closes the editor; shared
  recovery remains reachable. `SystemControlLifecycle` gates cursor activation.

### Bluetooth reconnect · `bluetooth`

- **Owner:** [BluetoothModule.swift](BluetoothModule.swift), including backend/policy;
  [CommandRunner.swift](CommandRunner.swift) runs external tools such as `blueutil`.
- **UI:** Sound & connections settings, Bluetooth widget; contextual Bluetooth access.
- **Resources/cleanup:** polling timer, connection-cycle cancellation, pending manual
  and audio intents, authorization manager. `stop(completion:)` cancels work and waits
  for an in-flight cycle; post-connect routing goes to Audio rather than a second owner.

### Audio · `audio`

- **Owner:** [AudioModule.swift](AudioModule.swift), including `CoreAudioBackend`.
- **UI:** Sound & connections settings and Audio widget. Selecting a microphone does
  not record audio or require microphone-recording permission.
- **Resources/cleanup:** discovery timer, route preferences, overrides and pending
  Bluetooth intent. `stop()` clears polling/callbacks/intent. The host retains this
  owner while Bluetooth needs it, even with the Audio feature off; automatic routing
  has a separate admission flag.

### Animations · `spaces`

- **Owners:** [AnimationPreferences.swift](AnimationPreferences.swift) for system
  preference changes; [SpacesModule.swift](SpacesModule.swift) for fast Space switching.
- **UI:** System settings, with desktop switching under Advanced; no widget.
  Desktop interception requires Accessibility and watchdog/readiness checks.
- **Resources/cleanup:** preference recovery marker, Space observer, interceptor/event
  tap, and gesture queue. Preference rollback restores previous values; suspend tears
  down interception and cancels/drains gestures; full stop removes the observer.
  [Vendor/strafe](Vendor/strafe) supplies the embedded engine, not this whole feature.

### Menu bar · `menuBar`

- **Owners:** `MenuBarModule` and `MenuBarSpacing` in [MenuBarModule.swift](MenuBarModule.swift).
- **UI:** System settings plus the module's chevron/divider status items; no popup widget
  or Screen Recording permission.
- **Resources/cleanup:** status items and original global spacing preferences/recovery
  state. Stop removes the hiding items and reveals icons; host spacing restoration is
  a separate path and can retain failed recovery for retry.

### Hold to quit · `quitGuard`

- **Owner/UI:** [QuitGuard.swift](QuitGuard.swift) owns the input state machine and
  countdown HUD. Configuration lives in Input settings; plain ⌘Q is the quick action.
- **Permission/resources:** Accessibility; session keyboard tap/run-loop source,
  countdown polling, captured foreground identity and HUD. `stop()` cancels the hold,
  removes interception/timers and hides the HUD. Requests normal application quit.

### Keep awake · `keepAwake`

- **Owner:** [KeepAwakeModule.swift](KeepAwakeModule.swift), including `SystemPowerAssertions`.
- **UI:** System settings and Keep awake widget; no TCC permission grant.
- **Resources/cleanup:** IOKit system/display assertions, deadline/update timer and
  app launch/exit observers. `deactivate()` removes observers/timer and stops reasons;
  assertion release failures have feature-owned error/cleanup state. Check the pending
  setup assertion blocker in [release notes](RELEASE-NOTES-1.0-DRAFT.md) before release.

### Window positions · `windows`

- **Owner:** [WindowPositions.swift](WindowPositions.swift), including matching,
  planning and `AXWindowPositionBackend`.
- **UI:** Displays settings via [WindowPositionsView.swift](WindowPositionsView.swift);
  Window layouts widget and optional Displays restore controls. Accessibility required.
- **Resources/cleanup:** saved layout/configuration data in preferences, wake/sleep
  observers and generation-checked queued moves. `stop()` invalidates work and removes
  observers/connection registration; it keeps saved layouts. Host display settling
  gates restoration; full-screen windows and Space assignments remain outside scope.

### Clipboard · `clipboard`

- **Owners:** [ClipboardHistory.swift](ClipboardHistory.swift) owns capture/retention
  policy and archive I/O; [ClipboardModule.swift](ClipboardModule.swift) owns native
  pasteboard access, shortcut registration, panel, thumbnails and presentation.
- **UI:** Clipboard settings, Clipboard widget and nonactivating ⌘⇧V panel. No
  Accessibility or Screen Recording grant for these clipboard operations.
- **Resources/cleanup:** polling/age timers, Carbon hotkey/handler, panel and memory
  entries; optional unencrypted JSON archive. Stop removes those runtime resources;
  disk retention is separate. Host unload/quit first retries pending storage work and
  can veto exit. See [privacy/defaults](README.md#clipboard-privacy-and-retention).

### Mouse · `mouse`

- **Owners:** `MouseModule`/`MouseLifecycle` in [MouseModule.swift](MouseModule.swift),
  [MouseSystemBackend.swift](MouseSystemBackend.swift), and C boundary [MouseHID/MouseHID.c](MouseHID/MouseHID.c).
- **UI:** Input settings with explicit Apply/Restore; no widget or Accessibility tap.
- **Resources/cleanup:** mouse-class IOKit runtime values and recovery JSON. Lifecycle
  startup/disable/quit paths restore originals and retain unresolved owned changes.
  Enabling does not apply tuning. The scroll-policy seam is not an installed wheel
  interceptor or a qualified physical-device classifier.

## Shared host and safety code

| File | Responsibility |
| --- | --- |
| [AppDelegate.swift](AppDelegate.swift) | Feature composition, callbacks, native windows, setup application, display transactions and termination wiring. |
| [HostTransactions.swift](HostTransactions.swift) | Action admission and ordered quit preparation/drain/cancel/approval; feature owners still perform cleanup. See [glossary](GLOSSARY.md). |
| [SystemControlLifecycle.swift](SystemControlLifecycle.swift) | Shared input/recovery readiness state and cursor reconciliation, not a general plugin lifecycle. |
| [DisplayRefreshGate.swift](DisplayRefreshGate.swift) | Coalesced display refresh/settling before input or window work resumes. |
| [SafetyWatchdog.swift](SafetyWatchdog.swift), [main.swift](main.swift) | Independent watchdog and helper/CLI entry paths in the same built executable. |
| [SourceUpdates.swift](SourceUpdates.swift) | Source-history checks and installer launch; not feature registration or plugin updates. |

Storage has feature owners: `ModuleSettings` stores enable choices, `UISettingsStore`
in `UISurfaces.swift` stores UI/setup state, and feature files own their policy data
and recovery journals. Clipboard archives are not part of widget/setup drafts.

## Why strafe is in `Vendor/`

We reuse strafe's gesture engine/interceptor, C gesture payload code, and dependencies
instead of importing its app/hotkey/menu implementation. The import is pinned at
**`37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7`**; see
[Vendor/strafe/UPSTREAM.txt](Vendor/strafe/UPSTREAM.txt). This is a source dependency,
not a feature-module directory, dynamic loader, or claim of full upstream app parity.

The current build uses `clang`/`swiftc` with explicit source inputs, not a Swift package
manifest. Vendoring keeps that input pinned for reproducible source selection and
lets us maintain the local [SwitchEngine.swift](Vendor/strafe/Swift/SwitchEngine.swift)
patch: cancel queued ramps, drain an active gesture before display changes/shutdown,
and inject phase posting for tests. It does not guarantee bit-for-bit builds across
different SDKs. `SpacesModule` wraps this dependency behind app-owned permission and
safety checks; the host must coordinate it with display transactions and quit.

The code carries MIT notices for strafe/InstantSpaceSwitcher and an embedded 0BSD
notice for joshuarli/iss payload work, not a GPL dependency. Preserve the complete
[vendor license and acknowledgments](Vendor/strafe/LICENSE). The integrated build
includes complete project/vendor notices before signing; real-bundle comparisons
and strict verification passed. See [packaging validation](PACKAGING-VALIDATION.md)
and the revision-bound [integration evidence](RELEASE-CHECKLIST.md#current-evidence).

## Test seams and evidence

[test.sh](test.sh) compiles native host/UI and feature code into an isolated test
executable. Feature protocols and injected factories, clocks, command runners,
presenters and persistence backends let tests exercise production actions without
performing the corresponding live OS effects.

- [Tests/main.swift](Tests/main.swift): display/helper/watchdog, Space engine,
  Bluetooth, keep-awake, window and source-update boundaries.
- [Tests/AudioTests.swift](Tests/AudioTests.swift), [Tests/MouseTests.swift](Tests/MouseTests.swift):
  fake routing and HID/recovery backends.
- [Tests/ClipboardTests.swift](Tests/ClipboardTests.swift),
  [Tests/ClipboardPresentationTests.swift](Tests/ClipboardPresentationTests.swift):
  fake pasteboard/temp archive and panel/presentation behavior.
- [Tests/UITests.swift](Tests/UITests.swift),
  [Tests/HostTransactionsTests.swift](Tests/HostTransactionsTests.swift): widget/setup,
  native owned-window/action seams and host admission/quit coordination.
- [Tests/install.sh](Tests/install.sh): mocked installer/source-update scenarios.

These seams do not establish physical-device behavior, live focus/shortcut delivery
or VoiceOver acceptance. Follow the revision-bound links in [VALIDATION.md](VALIDATION.md).
