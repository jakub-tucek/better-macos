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

Required fixes now running in isolated worktrees:

| Finding | Workstream | Status |
| --- | --- | --- |
| Immediate quit/module disable can miss newly committed display recovery | Core recovery | Fix and regression review pending |
| Setup display-wake Off leaves an existing assertion active | Core recovery | Fix and regression review pending |
| Settings Clear history lacks confirmation | UI polish | Fix and regression review pending |
| Clipboard copy instructions and empty audio preference menus mislead | UI polish | Fix and review pending |
| Installed bundle omits project/vendor license notices | Packaging | Fix and bundle verification pending |
| Unchanged-source installer can ignore a requested signing-identity change | Packaging | Fix and installer regression pending |
| README/roadmap/validation mix current behavior with historical evidence | Documentation | Consolidation pending |

Keep latest-main source update behavior explicit. Versioning, publication approval,
and native/hardware acceptance remain open. No tracked generated artifacts were
found that justified deletion; retain upstream notices and useful historical evidence.
