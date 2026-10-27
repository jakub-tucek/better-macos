# Local signing on each Mac

From a checkout, run once:

```sh
bash scripts/dev signing setup
bash scripts/dev signing status
bash build.sh
```

Setup reuses the selected valid certificate. With no selection, it reuses a single
available code-signing identity, or creates a ten-year local certificate if none
exists. Multiple available identities require an explicit choice:

```sh
security find-identity -v -p codesigning
BETTER_MACOS_SIGNING_IDENTITY=<full-fingerprint> bash scripts/dev signing setup
```

The new private key stays in this Mac's default user Keychain. Setup grants
user-domain code-signing trust and permits `/usr/bin/codesign` to access that key;
macOS may prompt for Keychain access or trust. Setup signs and verifies a disposable
probe before saving configuration. Temporary new key files are private and removed
on ordinary success/failure. No existing private keys are exported or synchronized.

Setup saves `bettermacos.signingIdentity` in user-global Git configuration when
that setting is absent. Existing global and repository selections remain intact.
Selection order is environment override, then Git's normal configuration precedence
(repository overrides global). Keep this machine-specific fingerprint out of shared
dotfiles copied to other Macs. Existing repository overrides continue to win.

Build, UI host, installer and deployment use `scripts/signing.py`. These commands
never create certificates. Missing/expired/ambiguous identities stop before building
or quitting; setup also refuses to replace a broken configured identity automatically.
`status` validates identity availability; setup additionally probes private-key access.
Builds verify the resulting signature. An installer environment override is persisted
in its checkout only after validation.

For a source install whose checkout has already been created, run setup there
(`~/Library/Application Support/Better macOS/source` by default), then rerun the
installer. Installation paths can be customized; use the actual checkout path.

If a key is locked, unlock its Keychain and retry. If import or trust fails, inspect
the named `Better macOS Local <UUID>` certificate in Keychain Access before retrying;
an imported identity may remain even though no Git configuration was saved. If a
configured certificate expired or was deleted, explicitly select its replacement.
Changing certificates may require renewed macOS permission grants. Permissions stay
per Mac; a local self-signed certificate does not provide notarization or a shared
cross-machine signing identity.

CI and isolated fixtures can explicitly select `BETTER_MACOS_SIGNING_IDENTITY=-`.
There is no implicit ad-hoc fallback; setup and local deployment reject `-`.

`python3 Tests/signing-test.py` uses isolated Git configuration and mocked Keychain
operations. It covers selection precedence, reuse, ambiguity, failure, explicit
ad-hoc policy and temporary-key cleanup without modifying the real Keychain.
