#!/usr/bin/env bash
# Usage: ci/make-module.sh <module> <unit|regression> [jobs]
source "$(dirname "$0")/common.sh"
ci_module "${1:-}"
case ${2:-} in unit|regression) ;; *) echo 'Target must be unit or regression' >&2; exit 2;; esac
jobs=${3:-$CI_JOBS}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || exit 2
ci_log "$1-$2" make -C "${CI_SOURCE_DIR}" -j"$jobs" "$1-$2"
