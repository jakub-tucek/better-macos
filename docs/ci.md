# Continuous integration

[The CI workflow](../.github/workflows/ci.yml) adds one GitHub-hosted arm64 job
for pull requests targeting `main`, pushes to `main`, and manual dispatch. It has
**not been executed on GitHub as part of this change**. Adding the workflow does
not enable Actions, approve fork runs, configure organization policies or make its
check required in branch protection. Independently reviewed integration is recorded
below; after an authorized push, record the actual run URL, source revision and results.

## Runner and toolchain choice

Official sources inspected on 2026-10-15:

- [GitHub's runner table](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
  lists `xcode-27` as a standard **arm64 public-preview** runner for public and
  private repositories. Preview availability is not an SLA or a successful run.
- [The Xcode 27 image inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
  reports image `20261006.0244.1`, macOS 27.0.1, Xcode 27.0 (`27A266a`) at
  `/Applications/Xcode_27.app`, its `Xcode_27.0.app` symlink, and macOS SDK 27.0.
- [The stable macOS 26 arm64 inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
  instead lists Xcode 26.6 and SDK 26.5. It is not evidence for hosted SDK 27.

The workflow explicitly selects `xcode-27` and Xcode 27.0 using `DEVELOPER_DIR`,
without changing global `xcode-select`. Before downloads/builds it asserts Darwin
and native `uname -m = arm64`, selected tools present, Apple Swift **6.4.x**, and
macOS SDK **27.0**. It logs the actual OS, image version, revision, Xcode, compiler
and SDK paths/version. Unexpected compiler/SDK drift fails rather than silently
falling back to another Xcode or accepting an untested baseline. Runner images and
the linked inventories can change; revisit selection deliberately on drift or
preview retirement. No third-party Xcode setup action or toolchain download.

This matches the compiler/SDK line of the [local compatibility evidence](validation/clt-compatibility.md),
not its host OS: that evidence used macOS 26.6.2, not the hosted image's macOS
27.0.1. The app still targets arm64/macOS 15+ in Swift **5 language mode**; the
Clipboard package declares Swift tools 6.0. Neither declaration proves an older
compiler/SDK can build the whole app. No lower-toolchain matrix or full minimum-OS
claim is introduced here.

## Checks and safety

In order, the job runs the existing contributor entry points and focused CI checks:

```sh
bash scripts/dev bootstrap
bash scripts/dev lint
bash scripts/dev format-check
bash scripts/dev-tools-test.sh
BETTER_MACOS_SIGNING_IDENTITY=- bash test.sh
bash Scripts/ci-whitespace-test.sh
bash Scripts/ci-whitespace.sh # event environment supplied by the workflow
```

See [development](development.md) for tool versions and checksum verification.
Bootstrap downloads only the pinned tools into ignored `build/dev-tools/`; it
does not trust image-provided SwiftLint/SwiftFormat or install global packages.
`test.sh` owns app build/signature verification, state compiler checks, real and
relocated-bundle packaging, build-failure fixtures, named Swift Testing policy
suites, the legacy isolated runner and mocked installer scenarios. It uses
explicit **ad-hoc signing**, not Developer ID secrets or a release identity.
The workflow does not edit existing build/test/tooling scripts.

### Committed whitespace ranges

[`Scripts/ci-whitespace.sh`](../Scripts/ci-whitespace.sh) checks committed changes,
not unstaged changes in a clean checkout. Checkout uses `fetch-depth: 0` for full
history. Event metadata enters through step environment variables, never shell
source interpolation; the helper validates full commit SHAs and required objects.
It runs in the caller's repository and logs the exact checked endpoints:

- **PR:** `merge-base(event base SHA, actual PR head SHA)..actual PR head SHA`.
  Builds still use GitHub's default synthetic merge checkout, but whitespace checks
  use the PR's real changes, including earlier commits and fork heads reachable
  through that merge's parents. Advancing the base branch does not change this
  comparison to a synthetic merge patch.
- **Push:** event `before..sha`, covering the whole pushed net patch, not just the
  final commit. An all-zero `before` (new branch) compares the empty tree to `sha`,
  including root-commit content.
- **Manual dispatch:** selected commit's first parent to that commit; for a root
  commit, empty tree to that commit. This is a single-commit check, not a PR range.

Checks use `git diff --check` between these explicit endpoints. They detect bad
whitespace remaining in the net patch, not whitespace introduced and removed
within the range. Missing/invalid event SHAs, unavailable objects (for example an
unreachable pre-force-push commit), or no PR merge base fail closed; the helper
does not substitute `HEAD`, guess a range or fetch with persisted credentials.
Full-history checkout normally supplies PR/fork parents and push history, but is
not a promise that GitHub retains every obsolete event object.

[`Scripts/ci-whitespace-test.sh`](../Scripts/ci-whitespace-test.sh) runs offline in
a disposable Git repository, testing earlier-commit whitespace in multi-commit
PR/push ranges, an advanced base and synthetic merge checkout, clean ranges,
clean/bad roots, zero-before pushes, invalid/missing metadata and failure/log
propagation through the workflow's `pipefail`/`tee` pattern. It does not alter the
real checkout or use the network.

No production app install/launch, real installer, TCC grants, live clipboard/input,
display/audio changes, notarization or release publication are requested. Existing
tests launch disposable subprocesses and mount owned AppKit/SwiftUI windows with
isolated preferences and injected backends. Thus the suite is **not purely
headless**: WindowServer/AppKit layout, focus and rendering must work in the hosted
session. Hosted feasibility is unverified until a real run; failures must remain
visible, not be skipped or converted to success. This is not XCUITest app-driving
automation, physical-device acceptance or closure of [release gates](releases/checklist.md).

Each shell step uses `-euo pipefail`, including commands piped to `tee`, so a
failing test cannot be hidden by successful logging. Logs are attempted on success
and failure via `always()`, retained seven days as `ci-logs-<run>-<attempt>`; checkout
failure, cancellation or runner loss can prevent logs/artifact upload. The job is
bounded to 45 minutes. Superseded PR jobs cancel; pushes/manual runs are not
canceled in progress. No source, SwiftPM, tool or signed-bundle caches are used:
each VM starts clean, avoiding stale source flags/signatures. Existing build
fixtures exercise incremental/stale-object behavior; this is not a new proof of
byte-identical clean/incremental builds across toolchains.

## Permissions and maintenance

Only `contents: read` is granted. Checkout does not persist Git credentials. There
is no `pull_request_target`, secret, deployment environment, privileged self-hosted
runner or write-back. Fork PRs use the ordinary `pull_request` approval/security
model. Artifact upload uses the Actions artifact service, not repository write
permissions; artifacts are diagnostics, not distributable app builds.

Action pins were resolved from the official tag-ref API, not guessed:

- [checkout v6.0.2](https://api.github.com/repos/actions/checkout/git/ref/tags/v6.0.2):
  `de0fac2e4500dabe0009e67214ff5f5447ce83dd`.
- [upload-artifact v7.0.0](https://api.github.com/repos/actions/upload-artifact/git/ref/tags/v7.0.0):
  `bbbca2ddaa5d8feaa63e36b76fdaad77386f024f`.

Review upstream release/runner requirements when updating pins. A local YAML or
actionlint pass checks workflow structure, not remote scheduling, action execution,
GUI compatibility or full-suite success. Keep failures and later hosted evidence
revision-bound; do not replace the historical local validation records.

## Local validation of this addition · 2026-10-15

Based on `76dd542`, without running the full app suite again:

- YAML parsed; every `run` block passed `bash -n`; referenced command paths and
  local documentation links exist; `git diff --check` passed.
- The extracted preflight passed on the local arm64 macOS 26.6.2 / Xcode 27.0 /
  Swift 6.4 / SDK 27.0 host, overriding only `DEVELOPER_DIR` to the installed
  `/Applications/Xcode.app/Contents/Developer`. The hosted image's versioned
  symlink is not installed locally; its path is supported by the official inventory,
  not locally verified. This did not run a hosted job.
- An injected `uname -m = x86_64` made that same preflight exit 1. Replacing only
  `bash test.sh` in its extracted logging step with a command exiting 23 preserved
  exit 23 through `tee` and retained the diagnostic output.
- Repository-local **actionlint 1.7.12** passed with ShellCheck disabled (not
  installed) and only its obsolete runner-label diagnostic excluded:
  `-ignore '^label "xcode-27" is unknown\.'`. The March 2026 actionlint release
  predates this official preview label; no other validation diagnostic was ignored.
  The Darwin arm64 archive was verified **before extraction/execution** against
  [the official release API digest](https://api.github.com/repos/rhysd/actionlint/releases/tags/v1.7.12),
  SHA-256 `aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f`.
  Download, executable and temporary probes stayed in ignored `build/ci-validation/`;
  no Homebrew/global tool installation or external CI-helper dependency was introduced.

### Independent-review correction

Review of `d81d340` found that plain `git diff --check` checked only checkout dirt,
not the committed PR/push patch. The correction adds the explicit ranges and
offline fixtures above. Locally, `bash Scripts/ci-whitespace-test.sh`, helper and
fixture `bash -n`, all workflow shell-block syntax, YAML/actionlint (with the same
narrow preview-label exclusion), paths/links and patch whitespace passed. These
checks did not rerun `test.sh` or execute the workflow on GitHub.

These checks do not establish hosted availability, a green CI suite or minimum
toolchain support. No push, app install/launch, device mutation, tag, organization
setting or branch-protection change was performed.

## Main integration · 2026-10-15

Independently reviewed CLEAN commits `d81d340` and `5958a32` integrated without
conflicts as `9f26a88` and **`8a7eb9f1b16998a7e7a055514648738b66e07eff`**.
Production/build/test sources were unchanged; the separate source-move branch
awaiting review was not integrated. No full app suite was rerun for this CI-only change.

Actual local checks at that integrated revision:

- Offline whitespace fixtures passed: multi-commit PR/push patches, advanced base
  and synthetic merge, clean/root/zero-before ranges, invalid metadata and pipeline
  failure propagation. Log: `build/ci-integration-whitespace-fixtures.log`.
- The real main PR/push range `76dd542..8a7eb9f` and manual range
  `9f26a88..8a7eb9f` passed using full commit SHAs. Checkout is configured with
  `fetch-depth: 0`; credential persistence remains disabled.
- Ruby YAML parsing, all **eight** extracted workflow `run` blocks and helper/fixture
  shell syntax passed; referenced commands exist. Read-only permissions, full-history
  checkout and full-SHA action pins were checked. Ruby's YAML 1.1 parser represents
  the `on` key as Boolean true; actionlint separately validates Actions structure.
- Actionlint **1.7.12** passed with ShellCheck disabled and only the exact known
  preview-label exclusion documented above. Its existing upstream archive was
  SHA-256 verified before extraction into ignored `build/ci-validation/`; no network
  download or global tool installation was needed.
- The extracted preflight passed on local macOS 26.6.2 arm64 / Xcode 27 / Swift 6.4 /
  SDK 27.0, with command-scoped installed `DEVELOPER_DIR` and unset `SDKROOT`.
  Replacing only `bash test.sh` in its extracted logging step with intentional exit
  **23** retained that status and diagnostic through `tee`, without executing tests.
  Local probe logs: `build/ci-validation/integrated/ci-logs/`.
- All **208 local links and 32 fragments across 26 tracked Markdown documents**,
  committed/working diff checks and the CI-only file scope passed verification.

**Hosted execution remains unverified; branch protection is not configured.** No
remote green status, hosted runner execution, tested minimum toolchain, real app/OS
install, device/preference/permission mutation, push, tag or release is claimed.
At this CI-only revision, source organization remained pending separate review/integration.
Its subsequent [reviewed integration evidence](validation/source-organization.md#main-integration--2026-10-15)
does not change the hosted-execution or branch-protection limits above.
