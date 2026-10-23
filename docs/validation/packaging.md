# Packaging validation

## Bundle notices

`build.sh` copies the project MIT license, the complete vendored strafe license
(including jurplel's MIT acknowledgment and joshuarli/iss's 0BSD text), and
`Vendor/strafe/UPSTREAM.txt` into `Contents/Resources/Licenses` **before signing**.
No upstream license text is rewritten. `Tests/packaging.sh` compares all three
resources byte-for-byte with the repository sources and verifies the actual
built bundle with `codesign --verify --strict`.

Each build assembles a fresh `build/.bundle.XXXXXX/new.app`, with cleanup traps
restricted to that invocation's staging directory. Only a strictly verified
bundle replaces `build/Better macOS.app`; compile/sign/verification failures leave
the previous output untouched, and a failed publication restores it. Failed
rollback retains the old bundle in staging and prints its location. No app is
launched or quit. Source-install metadata records the repository root, not the
staging path. The three C objects are rebuilt and linked explicitly, excluding
unrelated stale object files.

`Tests/build.sh` exercises the real build script with injected compiler/signing
tools in a disposable source fixture. It verifies metadata, stale-resource
removal, exact notices, rejection of stale link inputs, staging cleanup, and
preservation of the previous bundle on compile, sign, verify, and publication
failures. A stale test resource seeded in this worktree's real build output was
also absent after the full real-build test run.

## Installer signing selection

- A nonempty `BETTER_MACOS_SIGNING_IDENTITY` is saved in the managed source checkout's
  local `bettermacos.signingIdentity` before considering a same-revision no-op.
  Any change from the previous configuration forces rebuilding, even if the
  installed signature already matches. `-` explicitly persists ad-hoc signing.
- With no environment selection, the saved configuration is used; absent
  configuration means ad-hoc signing. This matches `build.sh` selection semantics.
- Certificate names must match exactly one valid signing identity reported by
  `security find-identity -v -p codesigning`; full SHA-1 fingerprints are also
  accepted. Ambiguous names or unavailable certificates fail without falling
  back to ad-hoc signing, including on an otherwise up-to-date install.
- A no-op additionally requires a valid strict signature and the selected leaf
  certificate SHA-1 (a codesign certificate requirement), or `Signature=adhoc`
  for an ad-hoc selection. Thus changing configuration outside the installer or
  replacing the installed app's signer cannot hide behind a matching source SHA.
- The staged build must pass the same signature check before the installer asks
  the app to quit or replaces it. Failed signing leaves the installed app intact.
- Selecting a repeatable certificate does **not** guarantee macOS permission
  persistence, Developer ID distribution, or notarization. No such claims are made.

`Tests/install.sh` uses fake git, security, codesign, brew, app lifecycle commands,
and a build fixture in temporary directories. It checks same-SHA identity
selection/persistence/no-op, changed certificates, external configuration changes,
unavailable and ambiguous certificates, wrong build signer, fingerprint selection,
and explicit ad-hoc reset, alongside the existing rollback tests. It never edits
the real repository signing configuration or quits/opens the live app.
The fingerprint case includes lowercase alphabetic hex input resolved against
an uppercase certificate fingerprint, followed by a saved-configuration no-op.

## Scope and evidence

- Version metadata intentionally remains `CFBundleShortVersionString=0.4` and
  `CFBundleVersion=4`; no version bump, tag, publication, or push is performed.
- The updater downloads its installer script at the offered SHA, but that script
  still fetches and builds current `main` at execution time. A newer main may be
  installed than the offered revision. This work does not introduce source
  pinning or version channels.
- `BETTER_MACOS_SIGNING_IDENTITY=- bash test.sh`: real optimized Apple Silicon build,
  complete bundled-notice checks, strict ad-hoc signature verification, 3,997
  isolated Swift checks, and mocked installer cases pass. This is not evidence
  of Developer ID signing, notarization, or hardware qualification.
- `git diff --check` passes.
- Build revision metadata is the checkout's `HEAD` when `build.sh` runs, not a
  promised release SHA. Rebuild after the final release/integration commit in
  the parent checkout and verify `BetterMacOSRevision` against that commit before
  distributing; a pre-commit validation artifact is not the final release.
