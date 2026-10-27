#!/bin/bash
set -euo pipefail

REPOSITORY="https://github.com/jakub-tucek/better-macos.git"
STATE="${BETTER_MACOS_HOME:-$HOME/Library/Application Support/Better macOS}"
SOURCE="$STATE/source"
APP_DIR="${BETTER_MACOS_APP_DIR:-$HOME/Applications}"
APP="$APP_DIR/Better macOS.app"
FORCE=0
OPEN=1
LEGACY_BOOTSTRAP=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --no-open) OPEN=0 ;;
        --legacy-bootstrap) LEGACY_BOOTSTRAP=1 ;;
        *) echo "Usage: bash install.sh [--force] [--no-open] [--legacy-bootstrap]" >&2; exit 2 ;;
    esac
done
fail() { echo "Better macOS: $*" >&2; exit 1; }
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
cleanup() {
    local result=$?
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
    TARGET="${BETTER_MACOS_REVISION:-origin/main}"
    if [[ "$TARGET" != origin/main ]]; then
        [[ "$TARGET" =~ ^[a-f0-9]{40}$ ]] || fail "Invalid requested update revision."
        git -C "$SOURCE" merge-base --is-ancestor "$TARGET" origin/main || fail "Requested revision is not on origin/main."
        git -C "$SOURCE" merge-base --is-ancestor HEAD "$TARGET" || fail "Checkout is ahead of the offered revision; check for updates again."
    fi
    git -C "$SOURCE" merge --ff-only "$TARGET"
else
    git clone --branch main --single-branch "$REPOSITORY" "$SOURCE"
    if [[ -n "${BETTER_MACOS_REVISION:-}" ]]; then
        [[ "$BETTER_MACOS_REVISION" =~ ^[a-f0-9]{40}$ ]] || fail "Invalid requested update revision."
        git -C "$SOURCE" merge-base --is-ancestor "$BETTER_MACOS_REVISION" origin/main || fail "Requested revision is not on origin/main."
        git -C "$SOURCE" checkout -B main "$BETTER_MACOS_REVISION"
    fi
fi

REVISION="$(git -C "$SOURCE" rev-parse HEAD)"
# Save an explicit selection even when the revision is unchanged. A changed
# selection always rebuilds; an unchanged selection must also match the bundle.
CONFIGURED_IDENTITY="$(git -C "$SOURCE" config --get bettermacos.signingIdentity || true)"
SIGNING_IDENTITY="$(python3 "$SOURCE/scripts/signing.py" resolve --source "$SOURCE")"
IDENTITY_CHANGED=0
if [[ -n "${BETTER_MACOS_SIGNING_IDENTITY:-}" ]]; then
    if [[ "$BETTER_MACOS_SIGNING_IDENTITY" != "$CONFIGURED_IDENTITY" ]]; then IDENTITY_CHANGED=1; fi
    git -C "$SOURCE" config --local bettermacos.signingIdentity "$BETTER_MACOS_SIGNING_IDENTITY"
fi
CERTIFICATE_HASH=""
if [[ "$SIGNING_IDENTITY" != - ]]; then
    CERTIFICATE_HASH="$SIGNING_IDENTITY"
fi
signature_matches() {
    codesign --verify --strict "$1" 2>/dev/null || return 1
    if [[ "$SIGNING_IDENTITY" == - ]]; then
        codesign -dv "$1" 2>&1 | grep -qx 'Signature=adhoc'
    else
        codesign --verify --strict -R="certificate leaf = H\"$CERTIFICATE_HASH\"" "$1" 2>/dev/null
    fi
}
PLIST="$APP/Contents/Info.plist"
if [[ -e "$APP" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)" == io.github.jakub-tucek.better-macos ]] || fail "Destination contains a different app: $APP"
fi
INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :BetterMacOSRevision' "$PLIST" 2>/dev/null || true)"
MANAGED="$(/usr/libexec/PlistBuddy -c 'Print :BetterMacOSSourceInstall' "$PLIST" 2>/dev/null || true)"
INSTALLED_SOURCE="$(/usr/libexec/PlistBuddy -c 'Print :BetterMacOSSourceDirectory' "$PLIST" 2>/dev/null || true)"
if [[ "$FORCE" == 0 && "$IDENTITY_CHANGED" == 0 && "$INSTALLED" == "$REVISION" && "$MANAGED" == true && "$INSTALLED_SOURCE" == "$SOURCE" ]] && signature_matches "$APP"; then
    echo "Already up to date (${REVISION:0:7}). Use --force to rebuild."
    if [[ "$OPEN" == 1 ]]; then open "$APP"; fi
    exit 0
fi

brew install blueutil switchaudio-osx
echo "Building Better macOS from ${REVISION:0:7}…"
BETTER_MACOS_SIGNING_IDENTITY="$SIGNING_IDENTITY" BETTER_MACOS_SOURCE_INSTALL=1 BETTER_MACOS_INSTALL_DESTINATION="$APP" bash "$SOURCE/build.sh"
signature_matches "$SOURCE/build/Better macOS.app" || fail "Built app does not match the selected signing identity."
DEPLOY_ARGS=(--bundle "$SOURCE/build/Better macOS.app" --destination "$APP" --identity "${CERTIFICATE_HASH:--}")
if [[ "$OPEN" == 0 ]]; then DEPLOY_ARGS+=(--no-open); fi
if [[ "$LEGACY_BOOTSTRAP" == 1 ]]; then DEPLOY_ARGS+=(--legacy-bootstrap); fi
python3 "$SOURCE/scripts/deploy.py" "${DEPLOY_ARGS[@]}"
