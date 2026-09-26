#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
[[ ! -e $CI_SOURCE_DIR ]] || { echo "Source already exists: $CI_SOURCE_DIR; use a fresh --path" >&2; exit 2; }
mkdir -p "$CI_PATH"
git clone --no-hardlinks "$CI_REPO" "$CI_SOURCE_DIR"
remote=$(git -C "$CI_REPO" remote get-url origin)
git -C "$CI_SOURCE_DIR" remote set-url origin "$remote"
if [[ -n ${2:-} ]]; then
    git -C "$CI_SOURCE_DIR" fetch origin "$2"
    git -C "$CI_SOURCE_DIR" checkout --detach FETCH_HEAD
else
    # Overlay tracked edits, deletions, and nonignored new files without touching the checkout.
    python3 "$CI_SCRIPTS/snapshot.py" "$CI_REPO" "$CI_SOURCE_DIR"
fi
echo "Candidate commit: $(git -C "$CI_SOURCE_DIR" rev-parse HEAD)"
if [[ -z ${2:-} ]]; then echo 'Includes the current working-tree edits and nonignored new files.'; fi
if [[ $1 == 1 ]]; then
    # The dependency scripts run relative to install-deps and use generated build-opts.sh.
    (cd "$CI_SOURCE_DIR/install-deps"
        export GKYL_CI_JOBS=$CI_JOBS
        # Generate build options, then run each dependency with explicit fail-fast behavior.
        bash -e ./mkdeps.sh "--prefix=$CI_DEPS"
        for dependency in openblas superlu luajit; do
            bash -e "./build-$dependency.sh"
        done
        bash -e ./download-adas.sh)
fi
for file in OpenBLAS/lib/libopenblas.a superlu/include/slu_ddefs.h luajit/include/luajit-2.1/lua.h; do
    [[ -f $CI_DEPS/$file ]] || { echo "Missing $CI_DEPS/$file; use --build_deps or --deps DIR" >&2; exit 1; }
done
ci_configure "$CI_SOURCE_DIR" "$CI_PATH/install"
# Reaction data are not installed by make install.
if [[ -d $CI_DEPS/gkeyll/share/adas ]]; then
    mkdir -p "$CI_PATH/install/gkeyll/share"
    cp -a "$CI_DEPS/gkeyll/share/adas" "$CI_PATH/install/gkeyll/share/"
fi
