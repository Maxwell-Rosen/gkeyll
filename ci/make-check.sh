#!/usr/bin/env bash
# Usage: ci/make-check.sh <module> [jobs]
source "$(dirname "$0")/common.sh"
ci_module "${1:-}"
jobs=${2:-$CI_JOBS}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || exit 2
# An inherited GKYL_TEST_LOG disables the Makefile's own failure exit status.
unset GKYL_TEST_LOG
ci_log "$1-unit-run" make -C "$CI_SOURCE_DIR" -j"$jobs" "$1-check"
