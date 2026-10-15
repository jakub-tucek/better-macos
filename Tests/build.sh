#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fix-macos-build-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/source/Vendor/strafe/Swift" "$ROOT/bin"
cp build.sh Info.plist LICENSE "$ROOT/source/"
cp Vendor/strafe/LICENSE Vendor/strafe/UPSTREAM.txt "$ROOT/source/Vendor/strafe/"
touch "$ROOT/source/Vendor/strafe/Swift/fixture.swift"
cat > "$ROOT/bin/mock" <<'MOCK'
#!/bin/bash
set -euo pipefail
case "${0##*/}" in
    git) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
    xcrun)
        [[ "${MOCK_FAIL:-}" != compile ]] || exit 17
        [[ "$*" != *fixture-stale.o* ]] || exit 21
        while [[ "$1" != -o ]]; do shift; done
        printf '%s' fixture-binary > "$2" ;;
    codesign)
        if [[ "$1" == --force ]]; then
            [[ "${MOCK_FAIL:-}" != sign ]] || exit 18
            printf '%s' fixture-signature > "${@: -1}/Contents/signature"
        else
            [[ "${MOCK_FAIL:-}" != verify ]] || exit 19
            [[ -f "${@: -1}/Contents/signature" ]]
        fi ;;
    mv)
        if [[ "${MOCK_FAIL:-}" == publish && "$1" == */new.app ]]; then exit 20; fi
        /bin/mv "$@" ;;
esac
MOCK
chmod +x "$ROOT/bin/mock"
for command in git xcrun codesign mv; do ln -s mock "$ROOT/bin/$command"; done
export PATH="$ROOT/bin:$PATH" MAC_UTILS_SIGNING_IDENTITY=-
export FIX_MACOS_SOURCE_INSTALL=1 FIX_MACOS_INSTALL_DESTINATION="$ROOT/installed/Fix macOS.app"
run_build() { bash "$ROOT/source/build.sh" > "$ROOT/output" 2>&1; }
APP="$ROOT/source/build/Fix macOS.app"
mkdir -p "$ROOT/source/build/objects"
touch "$ROOT/source/build/objects/fixture-stale.o"
run_build
[[ "$(/usr/libexec/PlistBuddy -c 'Print :FixMacOSSourceDirectory' "$APP/Contents/Info.plist")" == "$ROOT/source" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :FixMacOSInstallDestination' "$APP/Contents/Info.plist")" == "$FIX_MACOS_INSTALL_DESTINATION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :FixMacOSRevision' "$APP/Contents/Info.plist")" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
echo 'PASS: staged build embeds repository source path, destination and HEAD, not staging paths'
touch "$APP/Contents/Resources/fixture-stale-resource"
cp -R "$APP" "$ROOT/previous.app"
for failure in compile sign verify publish; do
    export MOCK_FAIL="$failure"
    if run_build; then echo "Expected $failure failure" >&2; exit 1; fi
    diff -r "$ROOT/previous.app" "$APP"
    [[ -z "$(find "$ROOT/source/build" -maxdepth 1 -name '.bundle.*' -print)" ]]
done
unset MOCK_FAIL
echo 'PASS: compile, signing, verification and publication failures preserve previous bundle and clean staging'
run_build
[[ ! -e "$APP/Contents/Resources/fixture-stale-resource" ]]
[[ -z "$(find "$ROOT/source/build" -maxdepth 1 -name '.bundle.*' -print)" ]]
cmp LICENSE "$APP/Contents/Resources/Licenses/Fix-macOS-MIT.txt"
cmp Vendor/strafe/LICENSE "$APP/Contents/Resources/Licenses/strafe-LICENSE.txt"
cmp Vendor/strafe/UPSTREAM.txt "$APP/Contents/Resources/Licenses/strafe-UPSTREAM.txt"
echo 'PASS: fresh publication removes stale resources and preserves complete notices'
echo 'PASS: linking uses only the three freshly compiled owned objects'
