# Built-in modules and source map

Current source map, checked against `d6b216f` on 2026-10-23. For controls, defaults,
installation and privacy, use the [usage guide](usage.md). For test results and open
release gates, use [validation](validation/README.md). Directory organization is
not a completed lifecycle refactor; see [move evidence](validation/source-organization.md).

## Modules, not a plugin system

The twelve [AppModule](../Sources/App/AppModules.swift) cases retain persisted enable-choice IDs
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
Animations, MenuBar, QuitGuard, KeepAwake and Links. Shared display geometry, refresh and
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

- [AppStyle.swift](../Sources/SharedUI/AppStyle.swift): shared headings, neutral
  surfaces, contrast-aware borders, icon badges and compact launch rows. Used by
  Quick actions, Settings, setup, the right-click menu and action palettes.
- [UISurfaces.swift](../Sources/SharedUI/UISurfaces.swift): `SettingsGroup`, six `WidgetKind` cases,
  widget editor/popup, Settings shell, and quick-action views.
- [StatusQuickMenu.swift](../Sources/SharedUI/StatusQuickMenu.swift): fixed-size,
  nonactivating right-click panel, retained view tree, keyboard selection and
  outside-click lifetime. AppDelegate owns action admission and routing.
- [ActionPalette.swift](../Sources/SharedUI/ActionPalette.swift): shared centered
  panel lifetime, visual layout and action tiles used by Windows and
  [KeepAwakePalette.swift](../Sources/Features/KeepAwake/KeepAwakePalette.swift).
  Feature owners retain execution policy; opening either palette is read-only.
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
Cleanup describes the relevant owner and path, not proof of live acceptance.

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
- **Cycle delivery:** [BluetoothCycleDelivery.swift](../Sources/Features/Bluetooth/BluetoothCycleDelivery.swift)
  owns callback binding, worker/delivery ordering, cancellation gates and terminal
  lifetime. The owner retains admission, connection policy, Audio handoff and stop
  drain; see [ownership and checks](architecture/bluetooth-observation.md#cycle-delivery-ownership).
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
  assertion release failures retain feature-owned error/cleanup state. The setup
  assertion fix is integrated; see [core evidence](validation/README.md#reviewed-core-integration--dc96e9c--2026-10-15)
  and the remaining [release gates](releases/checklist.md#native-acceptance).
- **Boundary:** feature `prepareDisable()` retains/reactivates the same owner on
  failure; actions and post-chooser selections recheck host admission. Shutdown
  keeps the existing best-effort cleanup, without adding a quit veto. See the
  [owned-feature contract and evidence](architecture/keep-awake-feature.md).

### Links · `links`

- **Owner:** [LinksModule.swift](../Sources/Features/Links/LinksModule.swift) owns persisted rules
  (`links.config`), destination discovery and hand-off through an injected `LinkBrowserBackend`.
  Matching policy (domain with optional path, contains, `*` pattern) is pure Foundation in
  [LinkRouting.swift](../Sources/Features/Links/LinkRouting.swift).
- **UI:** Links settings via [LinksSettingsView.swift](../Sources/Features/Links/LinksSettingsView.swift);
  no widget or TCC grant. `Info.plist` declares http/https so the app can be chosen as the default
  browser; only the explicit **Make default browser** action changes that, never setup.
- **Boundary:** the host always constructs the owner. `application(_:open:)` routes every incoming
  link regardless of feature choice or host admission: a disabled feature or closed host skips rules
  and opens the fallback, then Safari, so links are never dropped. Settings edits, test opens and the
  default-browser change recheck host admission. Chrome profiles open through a short-lived
  `.crwebloc`; other Chromium browsers get `--profile-directory`. macOS protects a browser's
  data folder; choosing that folder in **Allow access to … profiles** is the per-folder consent
  that lets discovery read `Local State`. Profiles can also be added by folder name.
- **Resources/cleanup:** an App Nap–preventing activity (idle sleep still allowed) while enabled;
  stale `.crwebloc` files are removed at launch. Disabling keeps rules.

### Window positions · `windows`

- **Owner:** [WindowPositions.swift](../Sources/Features/Windows/WindowPositions.swift), including matching
  and planning. [WindowExecution.swift](../Sources/Features/Windows/WindowExecution.swift)
  owns verified discovery, native identity and write orchestration over a low-level
  access seam. [AXWindowNativeAccess.swift](../Sources/Features/Windows/AXWindowNativeAccess.swift)
  decodes native facts and preserves the `AXWindowPositionBackend` entry point.
  See [execution depth and interface](architecture/window-execution.md).
- **UI:** Displays settings via [WindowPositionsView.swift](../Sources/Features/Windows/WindowPositionsView.swift);
  Window layouts widget and optional Displays restore controls. The translucent
  [WindowActionPalette.swift](../Sources/Features/Windows/WindowActionPalette.swift)
  panel presents illustrated actions without activating the app. Host popup and
  right-click status menu open it; session-owned captured targets gate execution.
  Accessibility required for window actions.
- **Resources/cleanup:** saved layout/configuration data in preferences, wake/sleep
  observers and generation-checked queued moves. `stop()` invalidates work and removes
  observers/connection registration; it keeps saved layouts. Host display settling
  gates restoration; full-screen windows and Space assignments remain outside scope.
- **Keyboard tiling:** [WindowShortcuts.swift](../Sources/Features/Windows/WindowShortcuts.swift)
  provides opt-in Rectangle-style halves, quarters, thirds, two-thirds, maximize,
  almost maximize, center, restore and
  display movement without another vendor. [WindowShortcutSession.swift](../Sources/Features/Windows/WindowShortcutSession.swift)
  owns registration generations/retry, action outcomes and bounded original-frame
  lifetime. Production preset orchestration handles rollback over a low-level Carbon
  adapter. The owner retains admission and queued-layout cancellation. See
  [controls and current cross-display traversal](usage.md#window-shortcuts) and
  [lifecycle/validation history](validation/ui-window-shortcuts.md).

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

Moved to the [usage guide](usage.md#behavior-and-defaults), including current popup,
Settings, setup, palettes and window shortcuts. This heading remains for old links.

## Clipboard privacy and retention

See [Clipboard privacy and retention](usage.md#clipboard-privacy-and-retention).

## Source installation and signing

See [installation, updates and signing](usage.md#source-installation-and-signing)
or [developer commands and tested toolchains](development.md).

## Permissions and limits

See [permissions and limits](usage.md#permissions-and-limits) and the
[revision-bound acceptance matrix](validation/README.md).

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
