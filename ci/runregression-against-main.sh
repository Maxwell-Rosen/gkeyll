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
[[ -x $candidate_prefix/gkeyll/bin/gkeyll ]] || {
    echo "Missing candidate executable; run prepare and build with CI_PATH=$CI_PATH first" >&2; exit 2;
}
[[ ! -e $baseline_source ]] || { echo 'Baseline already exists; use a fresh CI_PATH' >&2; exit 2; }
git clone --no-hardlinks "$CI_REPO" "$baseline_source"
remote=$(git -C "$CI_REPO" remote get-url origin)
git -C "$baseline_source" fetch "$remote" "$CI_BASELINE"
git -C "$baseline_source" checkout --detach FETCH_HEAD
echo "Baseline commit: $(git -C "$baseline_source" rev-parse HEAD)"
ci_configure "$baseline_source" "$baseline_prefix"
make -C "$baseline_source" -j"$CI_JOBS" install
if [[ -d $CI_DEPS/gkeyll/share/adas ]]; then
    cp -a "$CI_DEPS/gkeyll/share/adas" "$baseline_prefix/gkeyll/share/"
fi
baseline=$baseline_prefix/gkeyll/bin/gkeyll
candidate=$candidate_prefix/gkeyll/bin/gkeyll
"$baseline" runregression configure --source-dir "$baseline_source"
"$baseline" runregression run --no-parallel --timeout 120 --jobs "$CI_JOBS" create
python3 "$CI_SCRIPTS/check-regression.py" "$baseline_prefix/gkeyll-results" create
"$candidate" runregression configure --source-dir "$CI_SOURCE_DIR"
for module in moments vlasov gyrokinetic pkpm; do
    for suite in creg luareg; do
        cp -a "$baseline_prefix/gkeyll-results/$module/$suite-accepted/." \
            "$candidate_prefix/gkeyll-results/$module/$suite-accepted/"
    done
done
"$candidate" runregression run --no-parallel --timeout 120 --jobs "$CI_JOBS" check
rc=0
python3 "$CI_SCRIPTS/check-regression.py" "$candidate_prefix/gkeyll-results" check || rc=$?
# Preserve databases (including per-test runlog) alongside the plain-text summary.
for module in moments vlasov gyrokinetic pkpm; do
    cp "$candidate_prefix/gkeyll-results/$module/regressiondb" "$CI_LOG_DIR/$module-regression.sqlite"
done
exit "$rc"
