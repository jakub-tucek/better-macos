# 1.0 release readiness

Status: preparation in progress. No release tag or publication authorized yet.

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
- [ ] Fix actionable findings in focused commits; keep feature behavior stable.
- [ ] Add regression coverage for bugs, then obtain independent follow-up review.
- [ ] Rerun integrated checks after code changes; avoid treating historical counts
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

Baseline at `f359f423bd7d3109fe519268776e6ca65d155344`:

- 3,997 isolated checks and seven mocked installer scenarios passed.
- Script syntax, plist lint, strict bundle signature, and diff checks passed.
- Bundle still reports version `0.4`, build `4`, targeting Apple Silicon/macOS 15+.
- Local build uses Apple Development signing; this is not a notarized distribution.

Reviewed integration status (remaining core work stays open):

| Finding | Workstream | Status |
| --- | --- | --- |
| Immediate quit/module disable can miss newly committed display recovery | Core recovery | Fix and regression review pending |
| Setup display-wake Off leaves an existing assertion active | Core recovery | Fix and regression review pending |
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
- Core fixes, watchdog/corrupt-journal reviews, remaining documentation release
  gates, version choice, native/hardware acceptance and publication remain open.
  This documentation-only evidence commit does not claim a final release artifact;
  rebuild and verify the chosen release revision before distribution.
