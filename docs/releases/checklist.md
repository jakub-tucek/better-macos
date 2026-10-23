# 1.0 release readiness

Status: preparation in progress. No release tag or publication authorized yet.

## Current status · 2026-10-23

`Info.plist` still declares **0.4 / build 4**; “1.0” is a release goal. Current
source through `1434620` includes tabbed Settings, Window actions and Keep awake
palettes, foreground-only shortcut discovery, and opposite-half cross-display
tiling. See [recent recorded checks](../validation/README.md#current-reading-order--2026-10-23).
The older integration records below are historical, not final-candidate proof.

The [project home](../../README.md), [usage guide](../usage.md), and
[documentation index](../README.md) describe current behavior. Their refresh does
not complete native acceptance, choose a version, authorize publication, or
constitute a fresh app/test run. Final release documentation approval remains open.

## Scope

Polish and verify the existing feature set. Keep unsupported functionality explicit:
mouse-wheel interception and per-device mouse tuning are not implemented. SQLite
migration and a general module-registration design are separate future work, not
requirements silently added to this release.

## Workstreams

- [x] **Correctness review:** independent adversarial review of lifecycle, setup,
  recovery, persistence, permissions, routing, installation, and source updates.
- [x] **UI/UX review:** compact widgets, Settings, setup, clipboard history, keyboard
  interaction, labels, empty states, and actionable failure states. Use synthetic
  fixtures for visual checks that would otherwise expose personal content.
- [x] **Verification baseline:** isolated suite, installer scenarios, script syntax,
  build/signature, metadata, and diff checks. Record the exact reviewed revision.
- [x] **Docs and cleanup audit:** identify stale instructions, contradictory status,
  release packaging gaps, and unused tracked artifacts before removing anything.

## Resolve and verify

- [x] Triage findings into release blockers, required polish, and deferred work.
- [x] Fix reviewed core/UI/packaging findings in focused commits; keep feature behavior stable.
- [x] Add regression coverage for those bugs, then obtain independent CLEAN follow-up review.
- [x] Rerun integrated checks after code changes; avoid treating historical counts
  as proof of the final release candidate.
- [ ] Complete native acceptance where tools permit it. Record permission-blocked
  and human-only checks as outstanding rather than counting them as passed.

### Native acceptance

- [ ] Popup opens and resizes correctly, including multiple display arrangements.
- [ ] Widget Edit/Done/Cancel, reordering, custom numeric entry, and device pickers.
- [ ] Settings reuse, keyboard traversal, text visibility, and light/dark appearance.
- [ ] Setup Skip/Back/Cancel/Finish, repeat setup, denied access, and partial results.
- [ ] Clipboard shortcut and destination focus, using deliberate disposable content.
- [ ] Normal quit, canceled quit, pending recovery, and restart behavior.
- [ ] Hardware checks appropriate to release claims: audio, displays/windows, mouse,
  awake sessions, and physical keyboard/trackpad behavior.

## Documentation and packaging

- [ ] README accurately describes install, supported features, defaults, permissions,
  quick widgets, Settings, setup, update behavior, and known limitations.
- [ ] Consolidate current validation guidance while preserving useful review evidence.
- [ ] Draft 1.0 release notes and upgrade/migration notes.
- [ ] Check license notices, vendored attribution, install URLs, and dependencies.
- [ ] Choose and verify bundle version/build number and release source revision.
- [ ] Confirm source-install/signing expectations; do not imply notarized binary
  distribution unless that packaging is actually prepared and verified.
- [ ] Review final diff and clean working tree; list any explicit release limitations.

## Publication gate

- [ ] Present final evidence, remaining manual checks, and proposed release notes.
- [ ] Obtain approval to push, tag, and publish 1.0.
- [ ] After approval: publish the chosen revision, verify remote installer/update
  discovery, and attach only the artifacts actually supported by this release.

## Current evidence

For later work, start with the [validation index](../validation/README.md).
The baseline and integration tables below retain their exact historical scope.

Baseline at `f359f423bd7d3109fe519268776e6ca65d155344`:

- 3,997 isolated checks and seven mocked installer scenarios passed.
- Script syntax, plist lint, strict bundle signature, and diff checks passed.
- Bundle still reports version `0.4`, build `4`, targeting Apple Silicon/macOS 15+.
- Local build uses Apple Development signing; this is not a notarized distribution.

Reviewed integration status (native acceptance and final release gates stay open):

| Finding | Workstream | Status |
| --- | --- | --- |
| Immediate quit/module disable can miss newly committed display recovery | Core recovery | Done: reviewed CLEAN; integrated `57075d4`, journal ownership regressions passed |
| Setup display-wake Off leaves an existing assertion active | Core recovery | Done: reviewed CLEAN; integrated `55fa91b`, isolated assertion release/retry regressions passed |
| New display mutations can outlive watchdog authorization | Core recovery | Done: reviewed CLEAN; integrated `cd49731` and `47eb5ff`, admission/executor boundary regressions passed |
| Unreadable display journals can be overwritten during initialization or reload/save | Core recovery | Done: reviewed CLEAN; integrated `a75dcf9` and `dc96e9c`, preservation regressions passed |
| Settings Clear history lacks confirmation | UI polish | Done: reviewed CLEAN; integrated `57e8738`, confirmation regressions passed |
| Clipboard copy instructions and empty audio preference menus mislead | UI polish | Done: reviewed CLEAN; integrated `57e8738`, UI regressions passed |
| Installed bundle omits project/vendor license notices | Packaging | Done: reviewed CLEAN; integrated `0ac6495` and `95e6433`, real signed-bundle notices verified |
| Unchanged-source installer can ignore a requested signing-identity change | Packaging | Done: reviewed CLEAN; integrated `38acfc8` and `95e6433`, signing/rollback regressions passed |
| README/roadmap/validation mix current behavior with historical evidence | Documentation | Reviewed docs integrated `e0933d1` and `fde1827`; final release documentation gate remains open |

Keep latest-main source update behavior explicit. Versioning, publication approval,
and native/hardware acceptance remain open. No tracked generated artifacts were
found that justified deletion; retain upstream notices and useful historical evidence.

### UI, packaging and documentation integration · 2026-10-15

Starting at `020de2d`, reviewed CLEAN commits were integrated separately:

| Work | Reviewed source commit | Main commit |
| --- | --- | --- |
| UI confirmations, audio empty states and navigation | `746b59401421b35758aebd10680dd2addede539e` | `57e8738be331b3ed51432c56a994c1425fb64485` |
| Complete bundled notices | `647b296ee4d6de900f41a4b9a8b95ed921dea2bb` | `0ac64954a62b31c1991916229dc4001f713dee31` |
| Installer signing selection | `0d10d914d30e604871ca88ba08c05705cac0481d` | `38acfc8cb3003612de0d898cb069079c88e773d7` |
| Fresh verified bundles and rollback | `b6ddc62569c3c93d3d13983b966d049db1e60f94` | `95e6433896428c1a16943a3e6cc4dff61e478cd4` |
| Release documentation and historical evidence separation | `8c96b8356547d204bb35ca450aad28260d5563e4` | `e0933d135b0a99f47bad5f2018c0f674a0bbf6a5` |
| Eleven compiled built-in modules, not downloadable plugins | `fde4811bd9ac53c14dfb6b0debd5849b45a6c07f` | `fde1827e00c2e118a33876146feb9afe0ff6a6a3` |

- Combined `bash test.sh` passed at code revision
  `95e6433896428c1a16943a3e6cc4dff61e478cd4`: **4,016 isolated checks**, thirteen
  mocked installer scenarios, four fresh-bundle fixture groups, and real signed
  bundle notice comparisons. Log: `build/release-ui-packaging-integration.log`.
- Documentation followed without source/test changes; README conflicts retained
  the new module catalog/structure and corrected Clipboard select-then-Return/Copy
  wording. Widget, Settings, wizard and host transaction coverage remains intact.
- Script syntax (`bash -n` for all six scripts), source/built plist lint, strict
  bundle signature, complete project/vendor notices, 119 local Markdown link targets
  across 18 documents and
  `git diff --check` passed. Bundle metadata embeds the tested code revision above,
  version `0.4`, build `4`, arm64/macOS 15+; signing is Apple Development, not notarized.
- Identity selection changes automatically rebuild even at the same source SHA;
  `--force` remains an unconditional rebuild. Missing/ambiguous certificates fail
  closed. Fresh builds verify before publication and preserve the prior bundle
  on compilation/signing/verification/publication failures.
- No real app quit/launch, device mutation, clipboard action, release/tag/push was
  performed. Existing isolated/read-only tests and disposable fixtures only.
- At this historical integration, core fixes, watchdog/corrupt-journal reviews,
  remaining documentation release gates, version choice, native/hardware acceptance
  and publication remained open.
  This documentation-only evidence commit does not claim a final release artifact;
  rebuild and verify the chosen release revision before distribution.

### Core integration · 2026-10-15

Starting at clean main `b7a67ab`, all six reviewed source commits were unique and
cherry-picked in order without conflicts. Git patch-equivalence checks confirm
the integrated series; README voice, module documentation, reviewed UI/packaging
and the still-proposed architecture/tooling roadmap were preserved.

| Work | Reviewed source commit | Main commit |
| --- | --- | --- |
| Durable display-recovery ownership | `a95a0502ea0a2679ef45bc48f0014850708c6403` | `57075d4` |
| Setup display-wake assertion release | `dbfc59c091e5185cc58a897bb7556b79d09dd082` | `55fa91b` |
| Watchdog admission for new disables | `454591c569e8b4aced8c3748359f4652f9026327` | `cd49731` |
| Unreadable journal initialization preservation | `200a080980490a696992cec72ad82a63461dbcde` | `a75dcf9` |
| Delayed helper supervision recheck | `dd10b4ab3e9e7a13c820b07430952a11996cb330` | `47eb5ff` |
| Every journal reload/save validation | `ea47e6093818601f6889806dfcf4e3f8fdbd5bfa` | `dc96e9c` |

- Supplied independent final review: **CLEAN**, **297 targeted checks** at
  `ea47e60`. The implementer's **4,201** full-suite checks remain historical
  worktree evidence, not a claim about combined main.
- Combined `bash test.sh` passed at code revision
  `dc96e9c46e813d1608d3879f68f49fdfc3239a7a`: **4,220 isolated checks**, thirteen
  mocked installer scenarios, four fresh-bundle fixture groups and real signed
  bundle notice comparisons. Log: `build/release-core-integration.log` (ignored
  local build output). This is 19 checks above the core-only result because the
  reviewed UI regression coverage is also present.
- All six shell scripts passed `bash -n`; source/built plists passed lint.
  Strict bundle signature and all three exact project/vendor notice comparisons
  passed. Metadata embeds `dc96e9c46e813d1608d3879f68f49fdfc3239a7a`, version
  `0.4`, build `4`, arm64/macOS 15+. Signing is Apple Development, not notarized.
- Environment: macOS 26.6.2 (25G83), arm64, Apple Swift 6.4 in Swift 5 language
  mode, SDK 27.0. This does not establish acceptance across supported OS versions.
- Local Markdown validation passed: **104 file targets across 19 root documents**;
  fragments were not checked. `git diff --check` passed.
- No real app launch/quit, device/preference/permission mutation, version bump,
  push, tag or publication was requested or performed. Tests use isolated defaults,
  fake discovery/assertions/helpers and disposable process/installer fixtures;
  native hardware probes were not invoked. Separate tooling/AGENTS work is not
  integrated by this change.
- Native/hardware acceptance, final release docs/notes, version/revision choice,
  final artifact rebuild/review and publication approval remain open. A separate
  documentation evidence commit does not turn this tested code build into a final
  release artifact.
