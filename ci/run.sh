#!/usr/bin/env bash
set -euo pipefail
usage() {
    cat <<'HELP'
Usage: bash ci/run.sh [options]
  --machine linux          Linux CPU only in this initial version
  --path DIR               Source/build/install root (default ~/gkylsoft/build_DATE_TIME_PID)
  --log_dir DIR            Persistent logs (default ~/gkylsoft/ci-logs/<run name>)
  --build_deps             Build OpenBLAS, SuperLU, LuaJIT and download ADAS data
  --deps DIR               Reuse dependencies installed at DIR
  --jobs N                 Parallel jobs (default half the available CPUs)
  --skip_valcheck          Skip module Valgrind checks
  --skip_runregression     Skip comparison against main
  --commit REF | --pr N     Fetch and test a revision instead of the working tree
  --baseline REF           Baseline revision on origin (default main)
  --stage STAGE            all (default), prepare, build, modules, runregression
  --cpu                    Explicitly select CPU
Environment equivalents: CI_PATH, CI_LOG_DIR, CI_DEPS, CI_JOBS, CI_BASELINE.
Use the same CI_PATH across modular invocations. prepare requires a fresh source directory.
HELP
}
stage=all build_deps=0 skip_valcheck=0 skip_runregression=0 revision=
while (($#)); do
    case $1 in
        --help|-h) usage; exit 0;;
        --build_deps) build_deps=1; shift;;
        --skip_valcheck) skip_valcheck=1; shift;;
        --skip_runregression) skip_runregression=1; shift;;
        --cpu) shift;;
        --path|--log_dir|--deps|--jobs|--baseline|--stage|--machine|--commit|--pr)
            (($# >= 2)) && [[ -n $2 && $2 != --* ]] || { echo "Missing value for $1" >&2; exit 2; }
            case $1 in
                --path) export CI_PATH=$2;;
                --log_dir) export CI_LOG_DIR=$2;;
                --deps) export CI_DEPS=$2;;
                --jobs) export CI_JOBS=$2;;
                --baseline) export CI_BASELINE=$2;;
                --stage) stage=$2;;
                --machine) [[ $2 == linux ]] || { echo 'Only --machine linux is supported' >&2; exit 2; };;
                --commit|--pr)
                    [[ -z $revision ]] || { echo 'Use only one of --commit or --pr' >&2; exit 2; }
                    revision=$2
                    if [[ $1 == --pr ]]; then
                        [[ $2 =~ ^[1-9][0-9]*$ ]] || { echo 'PR must be a positive integer' >&2; exit 2; }
                        revision=refs/pull/$2/head
                    fi;;
            esac
            shift 2;;
        *) echo "Unsupported option: $1 (see --help)" >&2; exit 2;;
    esac
done
case $stage in all|prepare|build|modules|runregression) ;; *) echo "Unknown stage: $stage" >&2; exit 2;; esac
export CI_PATH=${CI_PATH:-$HOME/gkylsoft/build_$(date +%Y%m%d_%H%M%S)_$$}
source "$(dirname "$0")/common.sh"
# Existing Makefiles and dependency scripts require shell-safe, whitespace-free paths.
for path in "$CI_PATH" "$CI_LOG_DIR" "$CI_DEPS" "$CI_SOURCE_DIR"; do
    [[ $path =~ ^/[a-zA-Z0-9_./+-]+$ ]] || { echo "Use absolute paths without spaces or shell metacharacters: $path" >&2; exit 2; }
done
[[ $(realpath -m "$CI_LOG_DIR") != "$(realpath -m "$CI_PATH")"/* && $(realpath -m "$CI_LOG_DIR") != "$(realpath -m "$CI_PATH")" ]] || {
    echo 'Logs must be outside --path so they survive build cleanup' >&2; exit 2;
}
[[ $(realpath -m "$CI_SOURCE_DIR") != "$CI_REPO" && $(realpath -m "$CI_SOURCE_DIR") != "$CI_REPO"/* ]] || {
    echo 'The isolated source directory must be outside the working checkout' >&2; exit 2;
}
echo "Build: $CI_PATH"
echo "Logs:  $CI_LOG_DIR"
if [[ $stage == all || $stage == prepare ]]; then
    ci_log prepare bash "$CI_SCRIPTS/prepare.sh" "$build_deps" "$revision"
fi
if [[ $stage == all || $stage == build ]]; then
    ci_log install make -C "$CI_SOURCE_DIR" -j"$CI_JOBS" install
fi
rc=0
if [[ $stage == all || $stage == modules ]]; then
    for module in core moments vlasov gyrokinetic pkpm; do
        bash "$CI_SCRIPTS/make-module.sh" "$module" unit || rc=1
        bash "$CI_SCRIPTS/make-check.sh" "$module" || rc=1
        bash "$CI_SCRIPTS/make-module.sh" "$module" regression || rc=1
        if ((!skip_valcheck)); then bash "$CI_SCRIPTS/make-valcheck.sh" "$module" || rc=1; fi
    done
fi
if [[ $stage == runregression || ( $stage == all && $skip_runregression == 0 ) ]]; then
    bash "$CI_SCRIPTS/runregression-against-main.sh" || rc=1
fi
echo "Summary: $CI_LOG_DIR/summary.txt"
exit "$rc"
