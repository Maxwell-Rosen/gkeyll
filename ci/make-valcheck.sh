#!/usr/bin/env bash
# Usage: ci/make-valcheck.sh <module> [jobs]
source "$(dirname "$0")/common.sh"
ci_module "${1:-}"
jobs=${2:-1}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || exit 2
if [[ ${3:-} == --execute ]]; then
    command -v valgrind >/dev/null
    output=$(mktemp)
    trap 'rm -f "$output"' EXIT
    make -C "$CI_SOURCE_DIR" -j"$jobs" "$1-valcheck" 2>&1 | tee "$output"
    # checkval.sh reports memory errors in text without failing make.
    if grep -q 'has error issues or memory leaks' "$output"; then exit 1; fi
    # Preserve detailed diagnostics outside the disposable build tree.
else
    rc=0
    ci_log "$1-valcheck" bash "$CI_SCRIPTS/make-valcheck.sh" "$1" "$jobs" --execute || rc=$?
    mkdir -p "$CI_LOG_DIR/valgrind/$1"
    if [[ -d $CI_SOURCE_DIR/build/$1/unit ]]; then
        find "$CI_SOURCE_DIR/build/$1/unit" -name '*_val_err' -exec cp {} "$CI_LOG_DIR/valgrind/$1/" \;
    fi
    exit "$rc"
fi
