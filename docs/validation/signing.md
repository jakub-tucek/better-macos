# Local signing unification · 2026-10-27

Changes based on `dd88b91`, committed with this record.

Passed: 11 isolated signing-policy tests, source-installer fixtures, build fixtures,
12 deployment transaction tests, pinned lint/format, developer-tool fixtures, shell
syntax and whitespace checks. Logs: `build/signing-{policy,installer,build-fixtures,
deployment,lint,format,tools}.log`.

`bash scripts/dev signing setup` reused certificate
`562726BFD6C5E4972EFEDEC911BB41B3A0BBBEC1`, signed and strictly verified a disposable
probe, and saved that fingerprint in user-global Git configuration. The repository
selection is preserved. `bash build.sh` passed with that identity
(`build/signing-app-build.log`). No app installation or restart was performed.

The first probe failed while copying system-file metadata with `copy2`; copying
bytes and setting executable permissions fixed it. Early fixtures also exposed
Python 3.9's missing `TestCase.enterContext`; the tests now use `ExitStack`.

Keychain creation/import/trust failure and temporary-key cleanup have mocked
coverage. New-certificate creation on another Mac remains unverified. This run
does not claim renewed hardware, permission continuity, UI or full-suite acceptance.
The earlier macOS 27 gesture-fixture full-suite blocker remains recorded in
[deployment evidence](deployment.md).
