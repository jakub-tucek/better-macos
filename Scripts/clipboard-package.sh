#!/bin/bash
# Sourced by build.sh/test.sh. One configuration contract for SwiftPM and linking.
# Swift 6.0+ supports the native engine; pin it rather than assuming SwiftBuild's layout.
clipboard_package_arguments() {
    local configuration="${1:-release}"
    case "$configuration" in debug|release) ;; *) echo "Invalid package configuration: $configuration" >&2; return 2 ;; esac
    CLIPBOARD_PACKAGE_ARGS=(--package-path "$PWD" --scratch-path "$PWD/build/swiftpm"
        --build-system native --configuration "$configuration"
        --triple arm64-apple-macosx15.0 -Xswiftc -warnings-as-errors)
}

clipboard_package_build() {
    clipboard_package_arguments "${1:-release}" || return
    xcrun swift build "${CLIPBOARD_PACKAGE_ARGS[@]}" --product ClipboardPolicy || return
    CLIPBOARD_PACKAGE_BIN="$(xcrun swift build "${CLIPBOARD_PACKAGE_ARGS[@]}" --show-bin-path)" || return
    CLIPBOARD_PACKAGE_MODULES="$CLIPBOARD_PACKAGE_BIN/Modules"
    CLIPBOARD_PACKAGE_ARCHIVE="$CLIPBOARD_PACKAGE_BIN/libClipboardPolicy.a"
    # Native SwiftPM emits a module file, not necessarily a module directory.
    [[ -e "$CLIPBOARD_PACKAGE_MODULES/ClipboardPolicy.swiftmodule" && -f "$CLIPBOARD_PACKAGE_ARCHIVE" ]] || {
        echo "Missing ClipboardPolicy module/static archive in $CLIPBOARD_PACKAGE_BIN" >&2
        return 1
    }
}

clipboard_package_test() {
    local configuration="${1:-debug}"
    if [[ $# -gt 0 ]]; then shift; fi
    clipboard_package_arguments "$configuration" || return
    # Swift 6.4's native engine does not discover standalone CLT's Testing paths.
    # Keep this test-only workaround out of the production archive/link command.
    local developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
    local frameworks="$developer/Library/Developer/Frameworks"
    if [[ -d "$frameworks/Testing.framework" ]]; then
        local compiler
        compiler="$(xcrun --find swiftc)" || return
        CLIPBOARD_PACKAGE_ARGS+=(-Xswiftc -F -Xswiftc "$frameworks"
            -Xswiftc -plugin-path -Xswiftc "$(dirname "$compiler")/../lib/swift/host/plugins/testing"
            -Xlinker -rpath -Xlinker "$frameworks")
    fi
    xcrun swift test "${CLIPBOARD_PACKAGE_ARGS[@]}" "$@"
}
