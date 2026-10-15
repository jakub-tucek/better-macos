# Launch-at-login diagnosis and focused UX fix · 2026-10-15

Initial source inspected: `e58dfe9ec6a96969faa4e23c6024ad042676bca5`. Isolated
branch: `diagnose/login-at-launch`. Approved focused implementation: `22aa2dc`.
No live login-item registration, settings launch, installation or app launch/quit.

## Implemented behavior and evidence

`Sources/App/LoginService.swift` introduces a small injected `LoginServicing`
boundary with five typed states: the four current SMAppService states and an
unknown-future fallback. `SystemLoginService` alone wraps the UI's real login API;
no logger, package or automatic registration was added. The existing explicit
CLI commands are unchanged.

The General checkbox represents **registration intent**, not permission or proof
of a successful future launch. Enabled and approval-required are checked; approval
required has explicit guidance and a user-triggered **Open Login Items…** button.
Unregistered, not-found and unknown are unchecked, each with distinct truthful
text. Not-found does not assert that an Applications folder is mandatory. The
native control style is unchanged.

Login failures appear inline via dedicated `DashboardModel.loginError`; neither
failure nor success overwrites/clears the unrelated global Bluetooth error.
Successful explicit operations clear only the previous login error. Registration,
unregistration and opening settings all recheck host admission and require a live
host. App activation and opening Settings read status only; they never register,
retry registration, open system settings or write preferences. Startup keeps its
existing read-only status projection through `refreshPreferences()`.

Permanent regression: `Tests/LoginServiceTests.swift`, wired into the normal
isolated runner. The real host with an injected service first failed:
`FAIL: actual login callback retains registration intent while approval is pending`
before changing the old enabled-only projection (`build/login-red.log`). After
the fix, **44 isolated login checks pass** (`build/login-green.log`), including:
all five states; registration/unregistration success and failure; denial with
pending registration retained; external approval/revocation; no automatic API
writes; explicit settings opening; unrelated errors; canceled-quit reopening;
closed admission during asynchronous drain; retained callbacks after teardown;
and no preference writes.

Validation at implementation `22aa2dc`:

- Full `bash test.sh` passes: **4,410 isolated checks**, **10 policy tests in
  3 suites**, and **13 mocked installer scenarios**, including build/packaging and
  selected-toolchain state compiler fixtures (`build/login-final-full-suite.log`).
  The built bundle embeds implementation revision `22aa2dc`. An earlier run with
  one fewer login assertion passed 4,409 checks (`build/login-full-suite.log`). No
  real installer was executed.
- `DEVELOPER_DIR=/Library/Developer/CommandLineTools bash Tests/swiftui-compatibility.sh`
  passes (`build/login-clt-compiler-fixture.log`). The full suite also runs its
  selected-toolchain compiler fixture and build/packaging fixtures.
- Pinned SwiftLint on all six changed Swift files: zero violations
  (`build/login-lint-changed.log`). Full wrapper lint fails on exactly the four
  untouched Windows force casts already listed in `.swiftlint-baseline.json`.
  A diagnostic-only generated baseline compares structurally equal to the existing
  baseline; no tracked baseline or suppression was changed.
- Pinned full SwiftFormat with explicit absolute build exclusions: **0/49 files**
  need formatting (`build/login-final-format.log`). The unmodified wrapper scans
  generated SwiftPM output despite its relative build exclusion in this temporary
  `/private/var` worktree and fails on generated `runner.swift` whitespace.
  `scripts/dev-tools-test.sh` likewise fails on intentionally malformed generated
  fixture files meant to be excluded (`build/login-tooling-fixtures.log`). These
  tooling/path failures remain open; no blanket formatting/tooling edits were made.
- Ten native, owned-view snapshots (all statuses, light/dark) were rendered with
  `build/login-regression/login-tests --login-ui-fixtures build/login-ui-fixtures`.
  Representative pending-light and not-found-dark images were inspected: status,
  inline error and explicit button fit without clipping. The owned windows are
  not activated, so controls show inactive native tint; this is not live app,
  keyboard, VoiceOver or next-login acceptance. The permanent rendering route is
  `build/isolated-tests --login-ui-fixtures <directory>`.
- Independent review is still required before integration. No reviewer agent was
  spawned and no changes were made in main or the parallel Bluetooth/logging work.
- `git diff --check` and shell syntax checks for `build.sh` / `test.sh` pass.

## Outcome and limits

The original report is not reproduced against the live app: registering it,
clicking its live checkbox, relaunching it and logging out were not authorized.
The screenshot's unchecked checkbox does not distinguish registration failure,
approval-required status, an unregistered item, or stale presentation. The exact
JavaScript `parse(dateStr, 'MM/dd/yyyy', new Date())` fragment has no established
connection to this native Swift path; no JavaScript dependency was added.

The baseline isolated actual-host callback probe confirmed a narrower defect: a
`.requiresApproval` result was silently presented as an unchecked checkbox, with
no explanation or route to Login Items settings. It also confirmed that an old
Bluetooth/global error can remain after a successful login registration. Neither
finding establishes why this user's original click or subsequent login failed.

## Read-only host evidence

- `ps -axo pid=,command=` showed PID 17987 running the repository's
  `build/Fix macOS.app/Contents/MacOS/fix-mac-os --show-dashboard`, plus its watchdog.
- Neither `/Applications/Fix macOS.app` nor `~/Applications/Fix macOS.app` existed.
- The on-disk running-path bundle's plist reports version `0.4`, build `4`, and
  `FixMacOSRevision=aec5532f5067eedee417b3cdbaad6a8ba266535e`.
  This is disk metadata, not proof of the revision loaded by the process.
- Its on-disk signature is Apple Development, team `QEC369PJFV`;
  `codesign --verify --strict` succeeds. This does not establish its signature
  state at the time of the reported failure.
- Read-only `sfltool dumpbtm` showed the current user's record:
  `Identifier: 2.io.github.jakub-tucek.mac-utils`, name `Mac Utils`, disposition
  `[enabled, allowed, notified] (0xb)`, generation 4, pointing to that same
  repository build bundle. This is BTM metadata, not an in-process read of
  `SMAppService.mainApp.status`, nor a successful next-login test.
- A scoped two-hour unified-log query for this bundle/name in `fix-mac-os`,
  `backgroundtaskmanagementd`, and `smd` returned no matching records. No error
  code or denial reason was recovered.
- `git diff aec5532..e58dfe9 --` over the four relevant host/UI/entry-point files
  is empty. This establishes source parity between those revisions only, not
  the contents of the already-running binary.

## Baseline source path at `e58dfe9`

- `Sources/SharedUI/UISurfaces.swift:737` binds the General checkbox directly to
  `DashboardModel.launchAtLogin` and `onLoginChanged`. No login-specific guidance.
- `Sources/App/AppDelegate.swift:358-365` checks host admission, calls
  `SMAppService.mainApp.register()` / `.unregister()`, reports a thrown error via
  the shared `errorMessage`, then refreshes preferences.
- `Sources/App/AppDelegate.swift:1021` projects **only** `.enabled` to `true`.
  `.notRegistered`, `.requiresApproval`, and `.notFound` all become `false`.
- Login action success does not clear the shared error. Clearing that shared
  error indiscriminately would incorrectly erase unrelated Bluetooth failures.
- There is no login-specific observer or `applicationDidBecomeActive` refresh.
  Other refresh paths exist (opening Settings, toggling the popup, watchdog or
  display updates, preference callbacks); external approval changes need not
  immediately update an already-open Settings view.
- `Sources/App/main.swift:95-104` provides direct CLI registration commands.
  These were **not run**. The enable command labels every non-enabled status as
  requiring approval, including `.notFound`/`.notRegistered`.
- Login registration uses `SMAppService.mainApp`, not a project launchd plist.
  `install.sh` defaults to `~/Applications`; `build.sh` signs its output bundle.
  No source policy disables the checkbox based on install path or availability.

The local SDK's `ServiceManagement.framework/Headers/SMAppService.h` documents:
code signing is required (line 49); main-app registration launches on subsequent
logins (150); already-registered, user-denied and invalid-signature failures are
distinct (164-168); approval-required means the user must take action in System
Settings (22-25). Its `/Applications` recommendation is specifically for
LaunchDaemons (127-129), not a blanket main-app requirement. Do not recommend
moving/installing this app as a proven fix from the present evidence.

## Initial diagnostic feedback loop and results

Diagnostic artifacts are intentionally ignored, under `build/login-probe/` in
this worktree. `create.py` copies the **entire current production AppDelegate**,
replacing only its ServiceManagement import with an API-compatible fake. It
copies the existing test main, adds a login-only branch, and uses the repository's
real test compiler input list. Other host behavior and the actual model callback
are preserved. It reads existing main-worktree C objects/ClipboardPolicy archive;
it does not rebuild or replace the running bundle. Preferences use a unique
test suite which is removed afterwards; no app launch or real login API call.

The initial diagnosis used these commands (historical; superseded by the
permanent injected-service tests and rendering route above):

```sh
python3 build/login-probe/create.py
build/login-probe/login-tests --login-probe
build/login-probe/login-tests --login-probe --require-approval-feedback
```

The first two commands pass **9 checks**:

1. Thrown register failure leaves checkbox off.
2. The registration error is exposed.
3. Successful `.enabled` register checks the checkbox.
4. An unrelated old Bluetooth error survives that success.
5. Successful unregister unchecks it.
6. Successful `.requiresApproval` register silently leaves it unchecked.
7. `.notFound` also silently leaves it unchecked.
8. Unregister failure retains checked state and reports the failure.
9. Closed host admission prevents both callback operations.

The final command fails deterministically (exit 1):
`FAIL: approval-required registration must explain why login launch is unavailable`.
Its assertion uses the existing shared error as the only current explanatory
channel; a future fix should instead assert a dedicated typed login status.
At this initial diagnosis there was no green-after-fix claim; parent design
coordination preceded the implementation above. These fake results establish
presentation behavior, not OS acceptance. The old copied Swift host/main artifacts
were removed after the permanent injected seam replaced them; initial logs and
the diagnostic script remain ignored historical artifacts, not current test entry
points.

## Ranked hypotheses and predictions

1. **Approval state is hidden.** Inject `.requiresApproval`: checkbox returns off
   without explanation. Confirmed code-level gap; not confirmed user's OS state.
2. **Stale/older running presentation.** External OS state can change without a
   login-specific active-window refresh. Current BTM is enabled/allowed despite
   earlier screenshot. Still unproven for that screenshot.
3. **Real registration failure.** A thrown denial/signature/other OS error should
   leave checkbox off and report that error. Fake confirms callback behavior;
   no real error recovered, and current signature verifies.
4. **Build path alone prevents registration.** Weakly supported: current BTM
   already holds an enabled/allowed record pointing there. No blanket Applications
   requirement was found for the main-app API.

## Approved bounded design and remaining acceptance

The parent approved the focused typed service, dedicated presentation, explicit
settings action and read-only return-to-app refresh. The original draft's
enabled-only checkbox semantics were deliberately replaced: checked now means
**registered intent**, including explicit pending approval, not eligible-to-run.
No hard install-path gate or startup registration was added. Shared model/Settings
edits are limited to this login seam and still require independent review before
integration with the parallel Bluetooth and logging changes.

Remaining live evidence requires the user's clarification: does the checkbox
refuse to stay checked, or remain checked but fail at the next login? Capture the
exact login-action error and its time. A user-authorized next-login check is still
required; neither code changes nor this fake probe can establish it.
