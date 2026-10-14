#!/bin/bash
set -euo pipefail

REPOSITORY="https://github.com/jakub-tucek/fix-mac-os.git"
STATE="${FIX_MACOS_HOME:-$HOME/Library/Application Support/Fix macOS}"
SOURCE="$STATE/source"
APP_DIR="${FIX_MACOS_APP_DIR:-$HOME/Applications}"
APP="$APP_DIR/Fix macOS.app"
FORCE=0
OPEN=1
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --no-open) OPEN=0 ;;
        *) echo "Usage: bash install.sh [--force] [--no-open]" >&2; exit 2 ;;
    esac
done
fail() { echo "Fix macOS: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail "Requires Apple Silicon macOS (run outside Rosetta)."
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ]] || fail "Requires macOS 15 or newer."
xcrun --find swiftc >/dev/null 2>&1 || fail "Install Xcode Command Line Tools with: xcode-select --install; then rerun."
command -v git >/dev/null || fail "Git is required (included with Xcode Command Line Tools)."
if ! command -v brew >/dev/null && [[ -x /opt/homebrew/bin/brew ]]; then export PATH="/opt/homebrew/bin:$PATH"; fi
command -v brew >/dev/null || fail "Install Homebrew from https://brew.sh, then rerun this installer."
[[ "$STATE" == /* && "$APP_DIR" == /* ]] || fail "Installation paths must be absolute."

mkdir -p "$STATE" "$APP_DIR"
LOCK="$STATE/install.lock"
mkdir "$LOCK" 2>/dev/null || fail "Another install is running. If it was interrupted, remove $LOCK and retry."
STAGE=""
cleanup() {
    local result=$?
    if [[ -n "$STAGE" && -d "$STAGE" ]]; then
        if [[ -d "$STAGE/previous.app" && ! -e "$APP" ]]; then
            mv "$STAGE/previous.app" "$APP" || echo "Previous app remains at $STAGE/previous.app" >&2
        fi
        # Keep a previous app if rollback failed, rather than deleting it.
        if [[ ! -d "$STAGE/previous.app" || -d "$APP" ]]; then rm -rf "$STAGE"; fi
    fi
    rmdir "$LOCK" 2>/dev/null || true
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -e "$SOURCE" ]]; then
    [[ -d "$SOURCE/.git" ]] || fail "$SOURCE exists but is not an installer checkout."
    [[ "$(git -C "$SOURCE" remote get-url origin)" == "$REPOSITORY" ]] || fail "Source checkout has a different origin; leaving it untouched."
    [[ "$(git -C "$SOURCE" symbolic-ref --short HEAD)" == main ]] || fail "Source checkout is not on main; leaving it untouched."
    [[ -z "$(git -C "$SOURCE" status --porcelain)" ]] || fail "Source checkout has local changes; commit or move them before updating."
    git -C "$SOURCE" fetch origin main
    git -C "$SOURCE" merge-base --is-ancestor HEAD origin/main || fail "Source checkout has local commits; refusing to overwrite them."
    git -C "$SOURCE" merge --ff-only origin/main
else
    git clone --branch main --single-branch "$REPOSITORY" "$SOURCE"
fi

REVISION="$(git -C "$SOURCE" rev-parse HEAD)"
PLIST="$APP/Contents/Info.plist"
if [[ -e "$APP" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)" == io.github.jakub-tucek.mac-utils ]] || fail "Destination contains a different app: $APP"
fi
INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :FixMacOSRevision' "$PLIST" 2>/dev/null || true)"
MANAGED="$(/usr/libexec/PlistBuddy -c 'Print :FixMacOSSourceInstall' "$PLIST" 2>/dev/null || true)"
INSTALLED_SOURCE="$(/usr/libexec/PlistBuddy -c 'Print :FixMacOSSourceDirectory' "$PLIST" 2>/dev/null || true)"
if [[ "$FORCE" == 0 && "$INSTALLED" == "$REVISION" && "$MANAGED" == true && "$INSTALLED_SOURCE" == "$SOURCE" ]] && codesign --verify --strict "$APP" 2>/dev/null; then
    echo "Already up to date (${REVISION:0:7}). Use --force to rebuild."
    if [[ "$OPEN" == 1 ]]; then open "$APP"; fi
    exit 0
fi

brew install blueutil switchaudio-osx
if [[ -n "${MAC_UTILS_SIGNING_IDENTITY:-}" ]]; then
    git -C "$SOURCE" config --local macutils.signingIdentity "$MAC_UTILS_SIGNING_IDENTITY"
fi
echo "Building Fix macOS from ${REVISION:0:7}…"
FIX_MACOS_SOURCE_INSTALL=1 FIX_MACOS_INSTALL_DESTINATION="$APP" bash "$SOURCE/build.sh"
STAGE="$(mktemp -d "$APP_DIR/.fix-macos-install.XXXXXX")"
ditto "$SOURCE/build/Fix macOS.app" "$STAGE/new.app"
codesign --verify --strict "$STAGE/new.app"

# Quit via the app's normal recovery/drain path. Never kill a busy GUI.
osascript <<'APPLESCRIPT'
with timeout of 30 seconds
    if application id "io.github.jakub-tucek.mac-utils" is running then
        tell application id "io.github.jakub-tucek.mac-utils" to quit
    end if
end timeout
APPLESCRIPT
for ((attempt = 0; attempt < 60; attempt++)); do
    if ! pgrep -x fix-mac-os >/dev/null; then break; fi
    sleep 0.5
done
if pgrep -x fix-mac-os >/dev/null; then fail "The app is still busy. Finish its current operation and rerun the installer."; fi

if [[ -e "$APP" ]]; then mv "$APP" "$STAGE/previous.app"; fi
mv "$STAGE/new.app" "$APP"
echo "Installed $APP (${REVISION:0:7})."
if [[ "$OPEN" == 1 ]]; then open "$APP"; fi
