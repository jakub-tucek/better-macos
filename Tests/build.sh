#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fix-macos-build-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/source/Vendor/strafe/Swift" "$ROOT/source/Scripts" "$ROOT/source/Tests" "$ROOT/bin"
cp build.sh test.sh Package.swift Info.plist LICENSE "$ROOT/source/"
cp Scripts/clipboard-package.sh "$ROOT/source/Scripts/"
cp -R Sources Tests "$ROOT/source/"
cp Vendor/strafe/LICENSE Vendor/strafe/UPSTREAM.txt "$ROOT/source/Vendor/strafe/"
touch "$ROOT/source/Vendor/strafe/Swift/fixture.swift"
cat > "$ROOT/bin/mock" <<'MOCK'
#!/bin/bash
set -euo pipefail
case "${0##*/}" in
    git) if [[ "$1" != status ]]; then echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; fi ;;
    xcrun)
        if [[ "$1" == --find ]]; then echo /mock/usr/bin/swiftc; exit 0; fi
        if [[ "$1 $2" == 'swift build' ]]; then
            [[ "${MOCK_FAIL:-}" != package ]] || exit 22
            configuration=release
            args=("$@")
            for ((i=0; i < ${#args[@]}; i++)); do
                if [[ "${args[i]}" == --configuration ]]; then configuration="${args[i+1]}"; fi
            done
            bin="$PWD/build/swiftpm/fixture arm64/$configuration"
            if [[ "$*" == *--show-bin-path* ]]; then
                [[ "${MOCK_FAIL:-}" != package-path ]] || exit 27
                echo "$bin"; exit 0
            fi
            [[ "$*" == *'--product ClipboardPolicy'* && "$*" == *'--build-system native'* && "$*" == *'--triple arm64-apple-macosx15.0'* ]] || exit 23
            mkdir -p "$bin/Modules"
            if [[ "${MOCK_FAIL:-}" == package-output ]]; then exit 0; fi
            touch "$bin/libClipboardPolicy.a" "$bin/Modules/ClipboardPolicy.swiftmodule"
            exit 0
        fi
        if [[ "$1 $2" == 'swift test' ]]; then exit 0; fi
        [[ "${MOCK_FAIL:-}" != compile ]] || exit 17
        for arg in "$@"; do
            case "$arg" in
                *fixture-stale.o|*ClipboardHistory.swift|Sources/Features/Clipboard/Policy/*) exit 21 ;;
                *.swift)
                    [[ -f "$arg" ]] || exit 28
                    case "$arg" in Sources/*|Tests/*|Vendor/*|*/.bundle.*/DiagnosticBuild.swift) ;; *) exit 29 ;; esac ;;
            esac
        done
        if [[ "$1" == swiftc ]]; then
            for source in Sources/Core/ActivityJournal.swift Sources/SharedUI/ActivityView.swift Sources/Features/KeepAwake/KeepAwakeFeature.swift Sources/Features/KeepAwake/KeepAwakePresentation.swift Sources/Core/Diagnostics.swift Sources/Core/LoginDiagnostics.swift Sources/Features/Bluetooth/BluetoothObservation.swift Sources/Features/Bluetooth/BluetoothProfilerProcess.swift; do
                inputs=0
                for arg in "$@"; do
                    if [[ "$arg" == "$source" ]]; then inputs=$((inputs + 1)); fi
                done
                [[ "$inputs" == 1 ]] || exit 32
            done
            if [[ "$*" == *'-o build/isolated-tests'* ]]; then
                [[ "$*" == *'Tests/main.swift'* && "$*" != *'Sources/App/main.swift'* ]] || exit 30
            else
                [[ "$*" == *'Sources/App/main.swift'* && "$*" != *'Tests/main.swift'* ]] || exit 31
                generated=0
                for arg in "$@"; do
                    if [[ "$arg" == */.bundle.*/DiagnosticBuild.swift ]]; then
                        grep -qx 'let compiledDiagnosticRevision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$arg" || exit 33
                        grep -qx 'let compiledDiagnosticSourceState = "clean"' "$arg" || exit 33
                        generated=$((generated + 1))
                    fi
                done
                [[ "$generated" == 1 ]] || exit 34
            fi
            [[ "$*" == *'libClipboardPolicy.a'* && "$*" == *'/Modules'* ]] || exit 24
            archives=0
            for arg in "$@"; do
                if [[ "$arg" == */libClipboardPolicy.a ]]; then archives=$((archives + 1)); fi
            done
            [[ "$archives" == 1 ]] || exit 26
            for object in CStrafe IOHIDPayload MouseHID; do [[ "$*" == *"build/objects/$object.o"* ]] || exit 25; done
        fi
        while [[ "$1" != -o ]]; do shift; done
        if [[ "$2" == build/isolated-tests ]]; then
            printf '#!/bin/bash\nexit 0\n' > "$2"
            chmod +x "$2"
        else
            printf '%s' fixture-binary > "$2"
        fi ;;
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
for failure in package package-path compile sign verify publish; do
    export MOCK_FAIL="$failure"
    if run_build; then echo "Expected $failure failure" >&2; exit 1; fi
    diff -r "$ROOT/previous.app" "$APP"
    [[ -z "$(find "$ROOT/source/build" -maxdepth 1 -name '.bundle.*' -print)" ]]
done
unset MOCK_FAIL
echo 'PASS: package, compile, signing, verification and publication failures preserve previous bundle and clean staging'
# A missing moved source must fail even with an existing bundle and stale objects.
mv "$ROOT/source/Sources/SharedUI/StoredState.swift" "$ROOT/StoredState.swift"
if run_build; then echo 'Expected missing source failure' >&2; exit 1; fi
diff -r "$ROOT/previous.app" "$APP"
mv "$ROOT/StoredState.swift" "$ROOT/source/Sources/SharedUI/StoredState.swift"
echo 'PASS: missing organized source fails closed rather than reusing stale build outputs'
# A successful SwiftPM command without its expected output must also fail closed.
rm "$ROOT/source/build/swiftpm/fixture arm64/release/Modules/ClipboardPolicy.swiftmodule"
export MOCK_FAIL=package-output
if run_build; then echo 'Expected missing package output failure' >&2; exit 1; fi
diff -r "$ROOT/previous.app" "$APP"
unset MOCK_FAIL
run_build
[[ ! -e "$APP/Contents/Resources/fixture-stale-resource" ]]
[[ -z "$(find "$ROOT/source/build" -maxdepth 1 -name '.bundle.*' -print)" ]]
cmp LICENSE "$APP/Contents/Resources/Licenses/Fix-macOS-MIT.txt"
cmp Vendor/strafe/LICENSE "$APP/Contents/Resources/Licenses/strafe-LICENSE.txt"
cmp Vendor/strafe/UPSTREAM.txt "$APP/Contents/Resources/Licenses/strafe-UPSTREAM.txt"
echo 'PASS: fresh publication removes stale resources and preserves complete notices'
echo 'PASS: linking uses only the three freshly compiled owned objects'
# Exercise the real legacy compiler input list too, without running native UI.
for fixture in swiftui-compatibility diagnostics-regressions gesture-terminal-proof bluetooth-permission-regressions bluetooth-observation-regressions packaging build install; do printf '#!/bin/bash\nexit 0\n' > "$ROOT/source/Tests/$fixture.sh"; done
bash "$ROOT/source/test.sh" > "$ROOT/output" 2>&1
echo 'PASS: app and legacy tests link the package archive once, exclude its Swift sources and ignore stale C objects'
