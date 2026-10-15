#!/bin/bash
# Offline disposable Git histories; no app, network or live preferences.
set -euo pipefail
CHECK="$(cd "$(dirname "$0")" && pwd)/ci-whitespace.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fix-macos-ci-whitespace.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$ROOT/template"
git -c init.defaultBranch=main init -q --template="$ROOT/template" "$ROOT/repo"
cd "$ROOT/repo"
git config user.name 'CI fixture'
git config user.email 'ci-fixture@example.invalid'
git config commit.gpgsign false
git config core.whitespace 'blank-at-eol,blank-at-eof,space-before-tab'

commit() {
    git add .
    git commit -qm "$1"
    git rev-parse HEAD
}
check() {
    CI_DIFF_EVENT="$1" CI_DIFF_BASE="$2" CI_DIFF_HEAD="$3" CI_DIFF_BEFORE="$4" \
        bash "$CHECK" >"$ROOT/result.log" 2>&1
}
pass() {
    if ! check "$@"; then cat "$ROOT/result.log" >&2; exit 1; fi
}
reject() {
    if check "$@"; then echo "Expected whitespace rejection: $*" >&2; exit 1; fi
    grep -F 'trailing whitespace' "$ROOT/result.log" >/dev/null
}
zero=0000000000000000000000000000000000000000
printf 'clean root\n' >root.txt
root="$(commit root)"
pass workflow_dispatch '' "$root" ''
pass push '' "$root" "$zero"

printf 'bad line  \n' >bad.txt
bad="$(commit 'whitespace in earlier commit')"
printf 'later clean change\n' >later.txt
head="$(commit 'later clean commit')"
# A single-commit check would miss bad.txt. Both event ranges must reject it.
reject pull_request "$root" "$head" ''
reject push '' "$head" "$root"
reject push '' "$head" "$zero"
pass workflow_dispatch '' "$head" ''
[[ -z "$(git status --porcelain)" ]]

# Advance base independently and check while HEAD is a synthetic merge commit.
git checkout -qb base "$root"
printf 'base-only change\n' >base.txt
base="$(commit 'advanced base')"
git checkout -qb synthetic "$head"
git merge -qm 'synthetic merge' "$base"
reject pull_request "$base" "$head" ''
grep -F "Checking committed whitespace: $root..$head" "$ROOT/result.log" >/dev/null

printf 'fixed line\n' >bad.txt
clean="$(commit 'clean net patch')"
pass pull_request "$base" "$clean" ''
pass push '' "$clean" "$root"
pass workflow_dispatch '' "$clean" ''

# Root whitespace must not escape manual/new-branch checks.
printf 'root whitespace  \n' >root.txt
bad_tree="$(commit 'bad root content')"
# Create a root commit with that tree without changing the working tree.
bad_root="$(git commit-tree "$bad_tree^{tree}" -m 'isolated bad root')"
reject workflow_dispatch '' "$bad_root" ''
reject push '' "$bad_root" "$zero"

# Bad metadata/missing history must fail closed rather than check checkout dirt.
if check push '' "$clean" ''; then echo 'Accepted missing before SHA' >&2; exit 1; fi
if check pull_request "$zero" "$clean" ''; then echo 'Accepted missing base commit' >&2; exit 1; fi
if check workflow_dispatch '' '--help' ''; then echo 'Accepted invalid head SHA' >&2; exit 1; fi

# The workflow shell must keep a helper rejection nonzero through tee.
if CI_DIFF_EVENT=push CI_DIFF_HEAD="$bad_root" CI_DIFF_BEFORE="$zero" \
    bash --noprofile --norc -euo pipefail -c 'bash "$1" 2>&1 | tee "$2"' \
    bash "$CHECK" "$ROOT/pipeline.log"; then
    echo 'Whitespace failure hidden by tee' >&2; exit 1
fi
grep -F 'trailing whitespace' "$ROOT/pipeline.log" >/dev/null
echo 'CI whitespace fixtures passed (PR/push multi-commit, merge base/head, clean, root/zero-before, metadata, pipeline).'
