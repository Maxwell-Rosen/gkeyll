#!/usr/bin/env bash
# Build an independent baseline, then compare the candidate's serial C and Lua suites.
source "$(dirname "$0")/common.sh"
if [[ ${1:-} != --execute ]]; then
    ci_log runregression bash "$CI_SCRIPTS/runregression-against-main.sh" --execute
    exit
fi
baseline_source=$CI_PATH/baseline-source
baseline_prefix=$CI_PATH/baseline-install
candidate_prefix=$CI_PATH/install
regression_timeout=${CI_REGRESSION_TIMEOUT:-600}
[[ $regression_timeout =~ ^[1-9][0-9]*$ ]] || { echo 'CI_REGRESSION_TIMEOUT must be a positive integer' >&2; exit 2; }
# Test-level concurrency already uses CI_JOBS; avoid nested BLAS/OpenMP pools.
export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1
[[ -x $candidate_prefix/gkeyll/bin/gkeyll ]] || {
    echo "Missing candidate executable; run prepare and build with CI_PATH=$CI_PATH first" >&2; exit 2;
}
[[ ! -e $baseline_source ]] || { echo 'Baseline already exists; use a fresh CI_PATH' >&2; exit 2; }
git clone --no-hardlinks "$CI_REPO" "$baseline_source"
remote=$(git -C "$CI_REPO" remote get-url origin)
git -C "$baseline_source" fetch "$remote" "$CI_BASELINE"
git -C "$baseline_source" checkout --detach FETCH_HEAD
echo "Baseline commit: $(git -C "$baseline_source" rev-parse HEAD)"
# Use the candidate's test-selection policy on both sides. Otherwise main would
# still run tests this change explicitly disables. Solver code and inputs stay on main.
for module in moments vlasov gyrokinetic pkpm; do
    for suite in creg luareg; do
        if [[ $suite == creg ]]; then manifest=c_test_manifest.lua; else manifest=lua_test_manifest.lua; fi
        if [[ -f $CI_SOURCE_DIR/$module/$suite/$manifest ]]; then
            mkdir -p "$baseline_source/$module/$suite"
            cp "$CI_SOURCE_DIR/$module/$suite/$manifest" "$baseline_source/$module/$suite/$manifest"
        fi
    done
done
ci_configure "$baseline_source" "$baseline_prefix"
make -C "$baseline_source" -j"$CI_JOBS" install
if [[ -d $CI_DEPS/gkeyll/share/adas ]]; then
    cp -a "$CI_DEPS/gkeyll/share/adas" "$baseline_prefix/gkeyll/share/"
fi
baseline=$baseline_prefix/gkeyll/bin/gkeyll
candidate=$candidate_prefix/gkeyll/bin/gkeyll
# Preserve both sides' runlogs even when a runner or checker fails.
save_databases() {
    local side prefix module
    for side in baseline candidate; do
        if [[ $side == baseline ]]; then prefix=$baseline_prefix; else prefix=$candidate_prefix; fi
        for module in moments vlasov gyrokinetic pkpm; do
            if [[ -f $prefix/gkeyll-results/$module/regressiondb ]]; then
                cp "$prefix/gkeyll-results/$module/regressiondb" \
                    "$CI_LOG_DIR/$side-$module-regression.sqlite"
            fi
        done
    done
}
trap save_databases EXIT
rc=0
"$baseline" runregression configure --source-dir "$baseline_source"
"$baseline" runregression run --no-parallel --timeout "$regression_timeout" --jobs "$CI_JOBS" create || rc=$?
python3 "$CI_SCRIPTS/check-regression.py" "$baseline_prefix/gkeyll-results" create || rc=$?
"$candidate" runregression configure --source-dir "$CI_SOURCE_DIR"
for module in moments vlasov gyrokinetic pkpm; do
    for suite in creg luareg; do
        cp -a "$baseline_prefix/gkeyll-results/$module/$suite-accepted/." \
            "$candidate_prefix/gkeyll-results/$module/$suite-accepted/"
    done
done
"$candidate" runregression run --no-parallel --timeout "$regression_timeout" --jobs "$CI_JOBS" check || rc=$?
python3 "$CI_SCRIPTS/check-regression.py" "$candidate_prefix/gkeyll-results" check || rc=$?
exit "$rc"
