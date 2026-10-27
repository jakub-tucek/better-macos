#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/better-macos-install-test.XXXXXX")"
trap 'result=$?; if [[ "$result" != 0 && -f "$ROOT/output" ]]; then cat "$ROOT/output" >&2; fi; rm -rf "$ROOT"' EXIT
export MOCK_ROOT="$ROOT"
export BETTER_MACOS_HOME="$ROOT/state with spaces"
export BETTER_MACOS_APP_DIR="$ROOT/Applications"
export MOCK_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cp scripts/deploy.py "$ROOT/deploy.py"
unset BETTER_MACOS_SIGNING_IDENTITY
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/mock" <<'MOCK'
#!/bin/bash
set -euo pipefail
case "${0##*/}" in
    uname) [[ "$1" == -s ]] && echo Darwin || echo arm64 ;;
    sw_vers) echo 26.0 ;;
    xcrun) echo /mock/swiftc ;;
    brew) echo brew >> "$MOCK_ROOT/actions" ;;
    git)
        if [[ "$1" == clone ]]; then
            target="${@: -1}"
            mkdir -p "$target/.git"
            mkdir -p "$target/scripts"
            cp "$MOCK_ROOT/deploy.py" "$target/scripts/deploy.py"
            cp "$MOCK_ROOT/build-fixture.sh" "$target/build.sh"
        else
            shift 2
            case "$1" in
                remote) echo https://github.com/jakub-tucek/better-macos.git ;;
                symbolic-ref) echo main ;;
                status) if [[ "${MOCK_DIRTY:-0}" == 1 ]]; then echo ' M user-work.swift'; fi ;;
                merge-base) [[ "${MOCK_DIVERGED:-0}" == 0 ]] ;;
                rev-parse) echo "$MOCK_REVISION" ;;
                config)
                    if [[ "$*" == 'config --local --get bettermacos.signingIdentity' ]]; then
                        [[ ! -f "$MOCK_ROOT/signing-identity" ]] || cat "$MOCK_ROOT/signing-identity"
                    else
                        printf '%s' "${@: -1}" > "$MOCK_ROOT/signing-identity"
                    fi ;;
                 fetch|merge|checkout) : ;;
                *) exit 99 ;;
            esac
        fi ;;
    ditto) cp -R "$1" "$2" ;;
    security)
        [[ "${MOCK_CERT_UNAVAILABLE:-0}" != 1 ]] || exit 0
        echo '  1) 1111111111111111111111111111111111111111 "Fixture A"'
        echo '  2) 2222222222222222222222222222222222222222 "Fixture B"'
        echo '  4) ABCDEF0123456789ABCDEF0123456789ABCDEF01 "Fixture Hex"'
        if [[ "${MOCK_CERT_AMBIGUOUS:-0}" == 1 ]]; then
            echo '  3) 3333333333333333333333333333333333333333 "Fixture A"'
        fi ;;
    codesign)
        [[ "${MOCK_SIGNATURE_FAIL:-0}" == 0 ]] || exit 1
        app="${@: -1}"
        signature="$(cat "$app/Contents/fixture-signature")"
        if [[ "$1" == -dv ]]; then
            [[ "$signature" != - ]] || echo 'Signature=adhoc'
        elif [[ "$*" == *'-R='* ]]; then
            [[ "$*" == *"H\"$signature\""* ]]
        fi ;;
    osascript) cat >/dev/null; echo quit >> "$MOCK_ROOT/actions"; [[ "${MOCK_QUIT_FAIL:-0}" == 0 ]] ;;
    pgrep) exit 1 ;;
    open) echo open >> "$MOCK_ROOT/actions" ;;
    mv)
        if [[ "${MOCK_SWAP_FAIL:-0}" == 1 && "$1" == */new.app ]]; then exit 1; fi
        /bin/mv "$@" ;;
esac
MOCK
chmod +x "$ROOT/bin/mock"
for command in uname sw_vers xcrun brew git ditto codesign security osascript pgrep open mv; do ln -s mock "$ROOT/bin/$command"; done
export PATH="$ROOT/bin:$PATH"
cat > "$ROOT/build-fixture.sh" <<'BUILD'
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
echo build >> "$MOCK_ROOT/actions"
if [[ "${MOCK_BUILD_FAIL:-0}" == 1 ]]; then exit 17; fi
mkdir -p 'build/Better macOS.app/Contents/MacOS'
cat > 'build/Better macOS.app/Contents/MacOS/better-macos' <<'CLIENT'
#!/bin/bash
set -euo pipefail
if [[ "$1" == --deployment-quit && -e "$2" ]]; then osascript </dev/null; fi
/usr/bin/python3 - "$2" <<'PYCLIENT'
import json,sys,os,time,plistlib
path=os.path.join(sys.argv[1], 'Contents/Info.plist')
if not os.path.exists(path):
    print('null')
else:
    with open(path,'rb') as f: info=plistlib.load(f)
    print(json.dumps(dict(schema=1,pid=123,session='fixture',revision=info['BetterMacOSRevision'],timestamp=time.time(),blockers=[],checks={'watchdog':'ready'},configurationHash='fixture')))
PYCLIENT
CLIENT
chmod +x 'build/Better macOS.app/Contents/MacOS/better-macos'
case "${BETTER_MACOS_SIGNING_IDENTITY:--}" in
    'Fixture A'|1111111111111111111111111111111111111111) signature=1111111111111111111111111111111111111111 ;;
    'Fixture B'|2222222222222222222222222222222222222222) signature=2222222222222222222222222222222222222222 ;;
    abcdef0123456789abcdef0123456789abcdef01) signature=ABCDEF0123456789ABCDEF0123456789ABCDEF01 ;;
    -) signature=- ;;
    *) exit 18 ;;
esac
printf '%s' "${MOCK_BUILT_SIGNATURE:-$signature}" > 'build/Better macOS.app/Contents/fixture-signature'
/usr/bin/python3 - <<'PY'
import os,plistlib
with open('build/Better macOS.app/Contents/Info.plist','wb') as f:
    plistlib.dump({'CFBundleIdentifier':'io.github.jakub-tucek.better-macos',
        'BetterMacOSRevision':os.environ['MOCK_REVISION'], 'BetterMacOSSourceInstall':True,
        'BetterMacOSSourceDirectory':os.getcwd(),
        'BetterMacOSInstallDestination':os.environ['BETTER_MACOS_INSTALL_DESTINATION']},f)
PY
BUILD
revision() { /usr/libexec/PlistBuddy -c 'Print :BetterMacOSRevision' "$BETTER_MACOS_APP_DIR/Better macOS.app/Contents/Info.plist"; }
expect_failure() {
    if bash install.sh --no-open > "$ROOT/output" 2>&1; then cat "$ROOT/output" >&2; echo "Expected installer failure: $*" >&2; exit 1; fi
    [[ ! -d "$BETTER_MACOS_HOME/install.lock" ]]
}
bash install.sh --no-open > "$ROOT/output" 2>&1
[[ "$(revision)" == "$MOCK_REVISION" ]]
echo 'PASS: source install handles paths with spaces and embeds revision'
bash install.sh --no-open > "$ROOT/output" 2>&1
[[ "$(grep -c '^build$' "$ROOT/actions")" == 1 ]]
echo 'PASS: unchanged source skips rebuilding'
export MOCK_REVISION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export MOCK_DIRTY=1
expect_failure dirty
unset MOCK_DIRTY
export MOCK_DIVERGED=1
expect_failure local-commits
unset MOCK_DIVERGED
[[ "$(grep -c '^build$' "$ROOT/actions")" == 1 ]]
echo 'PASS: local changes and commits block updates before building'
export MOCK_BUILD_FAIL=1
expect_failure build
unset MOCK_BUILD_FAIL
export MOCK_SIGNATURE_FAIL=1
expect_failure signature
unset MOCK_SIGNATURE_FAIL
[[ "$(revision)" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
[[ "$(grep -c '^quit$' "$ROOT/actions" || true)" == 0 ]]
echo 'PASS: failed builds/signatures leave the old app running and installed'
export MOCK_QUIT_FAIL=1
expect_failure quit
unset MOCK_QUIT_FAIL
[[ "$(revision)" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
echo 'PASS: refused quit preserves the app (replacement rollback covered by deployment-test.py)'
bash install.sh --no-open > "$ROOT/output" 2>&1
[[ "$(revision)" == "$MOCK_REVISION" ]]
echo 'PASS: source update replaces the app after successful build and quit'
before="$(grep -c '^build$' "$ROOT/actions")"
bash install.sh --force --no-open > "$ROOT/output" 2>&1
[[ "$(grep -c '^build$' "$ROOT/actions")" == "$((before + 1))" ]]
echo 'PASS: force rebuild works for an unchanged revision'

signature() { cat "$BETTER_MACOS_APP_DIR/Better macOS.app/Contents/fixture-signature"; }
builds() { grep -c '^build$' "$ROOT/actions"; }
quits() { grep -c '^quit$' "$ROOT/actions"; }
export BETTER_MACOS_SIGNING_IDENTITY='Fixture A'
before="$(builds)"
bash install.sh --no-open > "$ROOT/output" 2>&1
[[ "$(cat "$ROOT/signing-identity")" == 'Fixture A' ]]
[[ "$(signature)" == 1111111111111111111111111111111111111111 && "$(builds)" == "$((before + 1))" ]]
bash install.sh --no-open > "$ROOT/output" 2>&1
[[ "$(builds)" == "$((before + 1))" ]]
echo 'PASS: same-SHA certificate selection is persisted, rebuilds ad-hoc app, then safely skips'

# Losing configuration must persist the new request and rebuild even if the
# installed bundle already has that certificate.
rm "$ROOT/signing-identity"
bash install.sh --no-open > "$ROOT/output" 2>&1
[[ "$(cat "$ROOT/signing-identity")" == 'Fixture A' && "$(builds)" == "$((before + 2))" ]]
unset BETTER_MACOS_SIGNING_IDENTITY
bash install.sh --no-open > "$ROOT/output" 2>&1
[[ "$(builds)" == "$((before + 2))" ]]
echo 'PASS: explicit identity survives same-SHA path and subsequent environment-free installs'

export BETTER_MACOS_SIGNING_IDENTITY='Fixture B'
bash install.sh --no-open > "$ROOT/output" 2>&1
[[ "$(signature)" == 2222222222222222222222222222222222222222 && "$(builds)" == "$((before + 3))" ]]
# External config changes must also be compared to the actual bundle signature.
printf '%s' 'Fixture A' > "$ROOT/signing-identity"
unset BETTER_MACOS_SIGNING_IDENTITY
bash install.sh --no-open > "$ROOT/output" 2>&1
[[ "$(signature)" == 1111111111111111111111111111111111111111 && "$(builds)" == "$((before + 4))" ]]
echo 'PASS: same-SHA different certificate and external configuration changes rebuild'

before="$(builds)"
quit_before="$(quits)"
export BETTER_MACOS_SIGNING_IDENTITY='Fixture B' MOCK_CERT_UNAVAILABLE=1
expect_failure unavailable-certificate
grep -q 'Selected signing certificate is unavailable' "$ROOT/output"
[[ "$(cat "$ROOT/signing-identity")" == 'Fixture B' ]]
[[ "$(builds)" == "$before" && "$(quits)" == "$quit_before" ]]
unset BETTER_MACOS_SIGNING_IDENTITY
expect_failure unavailable-saved-certificate
unset MOCK_CERT_UNAVAILABLE
export MOCK_BUILT_SIGNATURE=1111111111111111111111111111111111111111
expect_failure wrong-built-certificate
grep -q 'Built app does not match the selected signing identity' "$ROOT/output"
unset MOCK_BUILT_SIGNATURE
[[ "$(signature)" == 1111111111111111111111111111111111111111 && "$(quits)" == "$quit_before" ]]
echo 'PASS: unavailable and wrong signing certificates fail closed before quit, preserving old app'

export BETTER_MACOS_SIGNING_IDENTITY='Fixture A' MOCK_CERT_AMBIGUOUS=1
expect_failure ambiguous-certificate
grep -q 'Signing identity is ambiguous' "$ROOT/output"
unset MOCK_CERT_AMBIGUOUS
export BETTER_MACOS_SIGNING_IDENTITY=2222222222222222222222222222222222222222
bash install.sh --no-open > "$ROOT/output" 2>&1
[[ "$(signature)" == 2222222222222222222222222222222222222222 ]]
export BETTER_MACOS_SIGNING_IDENTITY=abcdef0123456789abcdef0123456789abcdef01
bash install.sh --no-open > "$ROOT/output" 2>&1
[[ "$(signature)" == ABCDEF0123456789ABCDEF0123456789ABCDEF01 ]]
[[ "$(cat "$ROOT/signing-identity")" == "$BETTER_MACOS_SIGNING_IDENTITY" ]]
before="$(builds)"
unset BETTER_MACOS_SIGNING_IDENTITY
bash install.sh --no-open > "$ROOT/output" 2>&1
[[ "$(builds)" == "$before" ]]
echo 'PASS: lowercase alphabetic fingerprint resolves uppercase certificate hash and then skips rebuild'
export BETTER_MACOS_SIGNING_IDENTITY=-
bash install.sh --no-open > "$ROOT/output" 2>&1
[[ "$(signature)" == - && "$(cat "$ROOT/signing-identity")" == - ]]
echo 'PASS: ambiguous names rejected, full fingerprint selection and explicit ad-hoc reset supported'
