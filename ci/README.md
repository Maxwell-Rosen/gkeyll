# Local and Ubuntu CI

Run the Linux CPU pipeline from any directory:

```bash
bash ci/run.sh --machine linux --build_deps
# Or reuse dependencies:
bash ci/run.sh --machine linux --deps "$HOME/gkylsoft" --path /tmp/gkeyll-ci
```

Install prerequisites on Ubuntu with:

```bash
sudo apt-get install build-essential gfortran cmake curl git rsync valgrind python-is-python3 python3-numpy libsqlite3-dev libopenblas-dev
```

The driver copies the current working tree (including nonignored edits and new
files) into a private clone. `--commit REF` or `--pr N` instead fetches a revision
from this checkout's `origin`. Neither changes your working checkout.

`--path` defaults to `~/gkylsoft/build_DATE_TIME_PID`; it holds sources,
dependencies, installations, and regression output. Use a fresh path outside your working checkout for each
run. Nothing is automatically deleted. Logs default to
`~/gkylsoft/ci-logs/<run name>` and survive deleting the build path. Each stage's
`.log` starts with its result and named failures, followed by full output;
`summary.txt` lists the stage results and named failures. Output streams to the terminal too.
`--log_dir` overrides the log location, which must be outside the build path.
Paths must be absolute and contain no spaces or shell metacharacters, as required
by the existing build scripts.

The default pipeline prepares dependencies/configuration, installs all solvers,
compiles each module's unit and C regression targets, runs unit tests and
Valgrind, then runs the manifest-selected serial C and Lua regression suites
against a separately built `origin/main`. `--baseline REF` selects another
baseline on origin. Both baseline and candidate have a 120-second per-test
regression timeout; timeouts fail CI. Skips in the manifests remain skips.
SQLite results are checked explicitly because runregression can exit successfully
with failed tests. A newly added test without a baseline fails comparison.
The baseline must support the current runregression interface and database schema.

Use `--skip_valcheck` and/or `--skip_runregression` for a shorter local run.
`--jobs N` controls compilation and regression concurrency (default half the
available CPUs). Unit and regression compilation failures do not prevent attempts
to test other modules. Preparation and installation failures also allow later
stages to run; the final exit status remains nonzero if any stage failed.
Compiler warnings alone do not fail CI: each stage has a `.warnings.txt` report,
and `summary.txt` includes warning counts and diagnostics with log locations.
Actions also displays a warning annotation and publishes the summary.

Actions uses the same stages and helpers:

The Ubuntu workflow sets `CI_JOBS` to `nproc`, using all available CPUs for
dependency builds, compilation, unit tests, Valgrind, and regression concurrency.

```bash
export CI_PATH=/tmp/gkeyll-ci CI_LOG_DIR=/tmp/gkeyll-ci-logs
bash ci/run.sh --build_deps --stage prepare
bash ci/run.sh --stage build
ci/make-module.sh vlasov unit
ci/make-check.sh vlasov
ci/make-module.sh vlasov regression
ci/make-valcheck.sh vlasov
bash ci/runregression-against-main.sh
```

Keep `CI_PATH`, `CI_LOG_DIR`, and any `CI_DEPS` override identical between steps.
The module helpers also accept an optional jobs argument, and work against the
current repository when `CI_PATH` is unset (or against `CI_SOURCE_DIR` explicitly).
`--stage modules` runs all module helpers; `--stage runregression` runs the baseline
comparison alone after preparation and installation.

This first version supports Linux CPU/serial execution. Perlmutter allocations,
GPU/MPI testing, HTML reports, and optional GitHub commit-status posting are not
implemented. Unsupported flags fail explicitly. No GitHub token file is needed;
private fetches use your existing Git credentials.

CI helper checks (no solver build required), from the repository root:

```bash
python3 ci/test-workflow.py
groovy ci/test-jenkins.groovy  # Requires a Groovy installation compatible with your JDK.
```

The Groovy checks parse the Jenkinsfiles and exercise stage/error and warning
helpers using stubbed Pipeline steps; deployment still requires a real Jenkins run.
