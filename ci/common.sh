#!/usr/bin/env bash
# Shared by the local driver and the individual Actions steps.
set -euo pipefail
CI_SCRIPTS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CI_REPO=$(cd "$CI_SCRIPTS/.." && pwd)
export CI_SOURCE_DIR=${CI_SOURCE_DIR:-${CI_PATH:+$CI_PATH/source}}
export CI_SOURCE_DIR=${CI_SOURCE_DIR:-$CI_REPO}
export CI_PATH=${CI_PATH:-$HOME/gkylsoft/build_$(date +%Y%m%d_%H%M%S)_$$}
export CI_LOG_DIR=${CI_LOG_DIR:-$HOME/gkylsoft/ci-logs/$(basename "$CI_PATH")}
export CI_DEPS=${CI_DEPS:-$CI_PATH/deps}
export CI_BASELINE=${CI_BASELINE:-main}
if [[ -z ${CI_JOBS:-} ]]; then
    if command -v nproc >/dev/null; then cpus=$(nproc); else cpus=$(sysctl -n hw.physicalcpu); fi
    CI_JOBS=$((cpus > 1 ? cpus / 2 : 1))
fi
export CI_JOBS
[[ $CI_JOBS =~ ^[1-9][0-9]*$ ]] || { echo 'CI_JOBS must be a positive integer' >&2; exit 2; }
mkdir -p "$CI_LOG_DIR"

ci_module() {
    case ${1:-} in core|moments|vlasov|gyrokinetic|pkpm) ;; *) echo "Invalid module: ${1:-missing}" >&2; exit 2;; esac
}

# Execute in a fresh shell so errexit remains active even when recording failures.
ci_log() {
    local name=$1 rc=0
    shift
    local raw="$CI_LOG_DIR/$name.output.log" log="$CI_LOG_DIR/$name.log"
    "$@" 2>&1 | tee "$raw" || rc=$?
    {
        if ((rc)); then echo "FAIL $name (exit $rc)"; else echo "PASS $name"; fi
        # Include test names as well as the failed stage before the full output.
        grep -E 'FAIL |\[ FAILED \]|has error issues or memory leaks|REGRESSION FAIL|^  (core|moments|vlasov|gyrokinetic|pkpm):' "$raw" || true
        printf '\nFull output:\n'
        cat "$raw"
    } > "$log"
    local warning_options=()
    if [[ ${GITHUB_ACTIONS:-} == true ]]; then warning_options+=(--github); fi
    python3 "$CI_SCRIPTS/report-warnings.py" "${warning_options[@]}" \
        --output "$CI_LOG_DIR/$name.warnings.txt" "$log"
    rm -f "$raw"
    sed '/^Full output:/,$d' "$log" >> "$CI_LOG_DIR/summary.txt"
    cat "$CI_LOG_DIR/$name.warnings.txt" >> "$CI_LOG_DIR/summary.txt"
    echo "Log: $log"
    return "$rc"
}

ci_configure() {
    local source=$1 prefix=$2
    (cd "$source" && ./configure "CC=${CC:-gcc}" --use-lua=yes --use-mpi=no \
        "--prefix=$prefix" "--lapack-inc=$CI_DEPS/OpenBLAS/include" \
        "--lapack-lib=$CI_DEPS/OpenBLAS/lib" "--superlu-inc=$CI_DEPS/superlu/include" \
        "--superlu-lib=$CI_DEPS/superlu/lib" "--lua-inc=$CI_DEPS/luajit/include/luajit-2.1" \
        "--lua-lib=$CI_DEPS/luajit/lib")
}
