#!/bin/bash
# Offline regressions for the tooling wrapper, never the app or live OS settings.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/dev-tools.env"
TOOLS="$ROOT/build/dev-tools"
[[ -x "$TOOLS/swiftlint-$SWIFTLINT_VERSION/swiftlint" && \
   -x "$TOOLS/swiftformat-$SWIFTFORMAT_VERSION/swiftformat" ]] || {
    echo "Run bash scripts/dev bootstrap first." >&2; exit 1;
}
FIXTURE="$(mktemp -d "$ROOT/build/.dev-tool-tests.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$FIXTURE/scripts" "$FIXTURE/build/dev-tools"
cp "$ROOT/scripts/dev" "$ROOT/scripts/dev-tools.env" "$FIXTURE/scripts/"
cp "$ROOT/.swiftlint.yml" "$ROOT/.swiftlint-baseline.json" "$ROOT/.swiftformat" "$FIXTURE/"

expect_failure() {
    local message="$1"
    shift
    if "$@" >"$FIXTURE/result.log" 2>&1; then
        echo "Expected failure: $*" >&2; exit 1
    fi
    grep -F "$message" "$FIXTURE/result.log" >/dev/null || {
        cat "$FIXTURE/result.log" >&2; exit 1;
    }
}

expect_failure 'Missing' bash "$FIXTURE/scripts/dev" lint
expect_failure 'Missing' bash "$FIXTURE/scripts/dev" format-check
expect_failure 'Unknown command' bash "$FIXTURE/scripts/dev" invalid

# A poisoned or accidentally replaced local tool must not be used/reused.
mkdir "$FIXTURE/build/dev-tools/swiftlint-$SWIFTLINT_VERSION"
cat >"$FIXTURE/build/dev-tools/swiftlint-$SWIFTLINT_VERSION/swiftlint" <<'SH'
#!/bin/bash
echo 0.0.0
SH
chmod +x "$FIXTURE/build/dev-tools/swiftlint-$SWIFTLINT_VERSION/swiftlint"
expect_failure 'Version mismatch' bash "$FIXTURE/scripts/dev" lint
expect_failure 'Version mismatch' bash "$FIXTURE/scripts/dev" bootstrap
rm "$FIXTURE/build/dev-tools/swiftlint-$SWIFTLINT_VERSION/swiftlint"
rmdir "$FIXTURE/build/dev-tools/swiftlint-$SWIFTLINT_VERSION"

# Fake only transport: real checksum code must reject bytes before extraction.
mkdir "$FIXTURE/transport"
cat >"$FIXTURE/transport/curl" <<'SH'
#!/bin/bash
while [[ $# -gt 0 ]]; do
    if [[ "$1" == --output ]]; then printf 'invalid archive' >"$2"; exit 0; fi
    shift
done
exit 2
SH
cat >"$FIXTURE/transport/unzip" <<'SH'
#!/bin/bash
touch "$EXTRACTION_MARKER"
exit 1
SH
chmod +x "$FIXTURE/transport/curl" "$FIXTURE/transport/unzip"
expect_failure 'SHA-256 mismatch' env PATH="$FIXTURE/transport:$PATH" \
    EXTRACTION_MARKER="$FIXTURE/extracted" bash "$FIXTURE/scripts/dev" bootstrap
[[ ! -e "$FIXTURE/extracted" && ! -e "$FIXTURE/build/dev-tools/swiftlint-$SWIFTLINT_VERSION" ]]

# Use the actual pinned tools for positive, negative and source-integrity checks.
# A new SourceKit-dependent rule must not be silently skipped by the wrapper.
"$TOOLS/swiftlint-$SWIFTLINT_VERSION/swiftlint" rules --enabled --config "$ROOT/.swiftlint.yml" >"$FIXTURE/rules"
if awk -F '|' '$8 ~ /yes/ { found = 1 } END { exit !found }' "$FIXTURE/rules"; then
    echo "Configured lint rules must not require SourceKit (see --disable-sourcekit)." >&2
    exit 1
fi
ln -s "$TOOLS/swiftlint-$SWIFTLINT_VERSION" "$FIXTURE/build/dev-tools/"
ln -s "$TOOLS/swiftformat-$SWIFTFORMAT_VERSION" "$FIXTURE/build/dev-tools/"
printf 'import Foundation\nimport Foundation\n' >"$FIXTURE/Fixture.swift"
cp "$FIXTURE/Fixture.swift" "$FIXTURE/before"
expect_failure 'duplicate_imports' bash "$FIXTURE/scripts/dev" lint
cmp "$FIXTURE/before" "$FIXTURE/Fixture.swift"
printf 'let value = 1  \n' >"$FIXTURE/Fixture.swift"
cp "$FIXTURE/Fixture.swift" "$FIXTURE/before"
expect_failure 'trailingSpace' bash "$FIXTURE/scripts/dev" format-check
cmp "$FIXTURE/before" "$FIXTURE/Fixture.swift"
printf 'let value = 1\n' >"$FIXTURE/Fixture.swift"
# Organized app and policy roots must remain checked, not hidden by exclusions.
for directory in Sources/App Sources/Core Sources/SharedUI Sources/Features/Mouse Sources/Features/Clipboard/Policy; do
    mkdir -p "$FIXTURE/$directory"
    printf 'import Foundation\nimport Foundation\n' >"$FIXTURE/$directory/Checked.swift"
    expect_failure 'duplicate_imports' bash "$FIXTURE/scripts/dev" lint
    printf 'let value = 1  \n' >"$FIXTURE/$directory/Checked.swift"
    expect_failure 'trailingSpace' bash "$FIXTURE/scripts/dev" format-check
    rm "$FIXTURE/$directory/Checked.swift"
done
for directory in Vendor build .build .swiftpm worktrees .worktrees generated Generated; do
    mkdir -p "$FIXTURE/$directory"
    printf 'import Foundation\nimport Foundation  \n' >"$FIXTURE/$directory/Ignored.swift"
done
bash "$FIXTURE/scripts/dev" lint
bash "$FIXTURE/scripts/dev" format-check
echo "Development tooling regressions passed (missing/version/checksum, non-mutating checks, exclusions)."
