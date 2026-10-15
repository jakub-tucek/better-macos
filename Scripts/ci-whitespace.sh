#!/bin/bash
# Check committed event changes in the caller's repository, not checkout dirt.
set -euo pipefail

fail() { echo "ci-whitespace: $*" >&2; exit 1; }
require_commit() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]] || fail "Expected a full commit SHA."
    git cat-file -e "$1^{commit}" || fail "Missing event commit $1; full event history is required."
}
empty_tree() { git hash-object -w -t tree --stdin </dev/null; }

head="${CI_DIFF_HEAD:-}"
require_commit "$head"
case "${CI_DIFF_EVENT:-}" in
    pull_request)
        require_commit "${CI_DIFF_BASE:-}"
        # The checkout may be GitHub's synthetic merge; check the actual PR head.
        base="$(git merge-base "$CI_DIFF_BASE" "$head")"
        ;;
    push)
        before="${CI_DIFF_BEFORE:-}"
        if [[ "$before" == 0000000000000000000000000000000000000000 ]]; then
            base="$(empty_tree)"
        else
            require_commit "$before"
            base="$before"
        fi
        ;;
    workflow_dispatch)
        # Manual runs check the selected commit, including all files at a root.
        if git rev-parse --verify "$head^" >/dev/null 2>&1; then
            base="$(git rev-parse "$head^")"
        else
            base="$(empty_tree)"
        fi
        ;;
    *) fail "Unsupported event: ${CI_DIFF_EVENT:-missing}" ;;
esac
printf 'Checking committed whitespace: %s..%s\n' "$base" "$head"
git diff --check "$base" "$head" --
