#!/usr/bin/env python3
"""Exercise CI reporting and failure propagation without building Gkeyll."""

import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest


CI = Path(__file__).resolve().parent


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gkeyll-ci-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, CI_PATH=str(self.root / "build"),
                        CI_LOG_DIR=str(self.root / "logs"), CI_JOBS="1",
                        GITHUB_ACTIONS="true")
        self.env.pop("CI_SOURCE_DIR", None)
        self.env.pop("CI_DEPS", None)

    def run_shell(self, command):
        return subprocess.run(["bash", "-c", command], env=self.env,
                              text=True, capture_output=True)

    def test_warning_formats_and_annotation(self):
        log = self.root / "compiler.log"
        log.write_text("file.c:3: warning: unused variable\n"
                       "file.c(4): warning #177: unused function\n"
                       "file.cu(5): warning #20012-D: ignored attribute\n"
                       "file.c:6: \033[35mwarning:\033[0m conversion\n"
                       "file.c:7: error: broken\n")
        result = subprocess.run(
            ["python3", str(CI / "report-warnings.py"), "--github",
             "--output", str(self.root / "warnings.txt"), str(log)],
            text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Compiler warnings: 4", result.stdout)
        self.assertIn("::warning title=Compiler warnings::", result.stdout)
        self.assertNotIn("error: broken", result.stdout)

    def test_warning_only_command_passes(self):
        result = self.run_shell(
            f'source "{CI}/common.sh"; '
            "ci_log compile bash -c 'echo file.c:2: warning: example >&2'")
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = (self.root / "logs/summary.txt").read_text()
        self.assertIn("PASS compile", summary)
        self.assertIn("Compiler warnings: 1", summary)
        self.assertIn("compile.log:", summary)

    def test_repeated_warnings_keep_counts_and_first_location(self):
        result = self.run_shell(
            f'source "{CI}/common.sh"; '
            "ci_log compile bash -c 'printf \"file.c:2: warning: example\\n%.0s\" {1..100}'")
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = (self.root / "logs/summary.txt").read_text()
        self.assertIn("Compiler warnings: 100", summary)
        self.assertEqual(summary.count("file.c:2: warning: example"), 1)
        self.assertIn("repeated 100 times; first occurrence", summary)
        self.assertEqual((self.root / "logs/compile.log").read_text().count(
            "file.c:2: warning: example"), 100)

    def test_publish_summary_size_limit(self):
        # Execute the workflow's actual shell block, including its Markdown fences.
        workflow = (CI.parent / ".github/workflows/ubuntu-latest.yml").read_text()
        block = workflow.split("      - name: Publish summary\n", 1)[1]
        block = block.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0]
        command = "\n".join(line[10:] for line in block.splitlines())
        logs = self.root / "logs"
        logs.mkdir()
        output = self.root / "step-summary.md"
        self.env["GITHUB_STEP_SUMMARY"] = str(output)
        limit = 1024 * 1024
        for content in (None, "", "PASS compile\n", "x" * (limit - 12),
                        "x" * (limit - 11), "é" * (limit // 2),
                        "warning: example\n" * 150000):
            with self.subTest(size=None if content is None else len(content.encode())):
                if output.exists():
                    output.unlink()
                if content is not None:
                    (logs / "summary.txt").write_text(content)
                result = self.run_shell(command)
                self.assertEqual(result.returncode, 0, result.stderr)
                if content is None:
                    self.assertFalse(output.exists())
                    continue
                published = output.read_text()
                self.assertLessEqual(output.stat().st_size, limit)
                if len(content.encode()) + 12 <= limit:
                    self.assertEqual(published, f"```text\n{content}```\n")
                else:
                    self.assertEqual(result.stdout, content)
                    self.assertIn("Publish summary", published)
                    self.assertIn("ubuntu-ci-logs", published)
                self.assertEqual((logs / "summary.txt").read_text(), content)

    def test_error_with_warning_keeps_exit_status(self):
        result = self.run_shell(
            f'source "{CI}/common.sh"; '
            "ci_log compile bash -c 'echo warning: example; exit 7'")
        self.assertEqual(result.returncode, 7, result.stderr)
        summary = (self.root / "logs/summary.txt").read_text()
        self.assertIn("FAIL compile (exit 7)", summary)
        self.assertIn("Compiler warnings: 1", summary)

    def test_regression_counts_and_failures(self):
        results = self.root / "results"
        for module in ("moments", "vlasov", "gyrokinetic", "pkpm"):
            directory = results / module
            directory.mkdir(parents=True)
            with sqlite3.connect(directory / "regressiondb") as db:
                db.execute("create table RegressionMeta (guid text)")
                db.execute("create table RegressionData (guid text, name text, test_type text, status integer)")
                db.execute("insert into RegressionMeta values ('old')")
                db.execute("insert into RegressionData values ('old', 'stale', 'c', -6)")
                db.execute("insert into RegressionMeta values ('current')")
                db.executemany("insert into RegressionData values ('current', ?, 'lua', ?)",
                               [(f"{module}/luareg/created.lua", -2),
                                (f"{module}/luareg/skipped.lua", -1)])
        result = subprocess.run(["python3", str(CI / "check-regression.py"), str(results), "create"],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("created=1 passed=0 skipped=1 failed=0", result.stdout)
        self.assertIn("4 completed; PASS", result.stdout)
        self.assertNotIn("stale", result.stdout)
        with sqlite3.connect(results / "moments/regressiondb") as db:
            db.execute("insert into RegressionData values ('current', 'moments/luareg/crash.lua', 'lua', -6)")
        result = subprocess.run(["python3", str(CI / "check-regression.py"), str(results), "create"],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("REGRESSION FAIL moments/luareg/crash.lua (lua): crash", result.stdout)
        self.assertNotIn("moments/moments", result.stdout)

    def test_candidate_runs_and_databases_survive_baseline_failure(self):
        # Exercise the real shell orchestration and checker with tiny fake runs.
        tools = self.root / "tools"
        tools.mkdir()
        git = tools / "git"
        git.write_text("#!/usr/bin/env bash\n"
                       'if [[ $1 == clone ]]; then mkdir -p "${@: -1}"; '
                       'printf "#!/bin/sh\\nexit 0\\n" > "${@: -1}/configure"; '
                       'chmod +x "${@: -1}/configure"; fi\n'
                       'echo stub-revision\n')
        git.chmod(0o755)
        make = tools / "make"
        make.write_text("#!/bin/sh\nexit 0\n")
        make.chmod(0o755)
        self.env["PATH"] = str(tools) + os.pathsep + self.env["PATH"]
        manifest_path = Path("moments/luareg/lua_test_manifest.lua")
        manifest = self.root / "build/source" / manifest_path
        manifest.parent.mkdir(parents=True)
        manifest.write_text('return { ignore = { tests = { "rt_known_failure" } } }\n')
        for side in ("baseline-install", "install"):
            exe = self.root / "build" / side / "gkeyll/bin/gkeyll"
            exe.parent.mkdir(parents=True)
            exe.write_text("""#!/usr/bin/env python3
from pathlib import Path
import sqlite3
import sys
root = Path(__file__).resolve().parents[2] / 'gkeyll-results'
for module in ('moments', 'vlasov', 'gyrokinetic', 'pkpm'):
    for suite in ('creg', 'luareg'):
        (root / module / (suite + '-accepted')).mkdir(parents=True, exist_ok=True)
if sys.argv[2] == 'run':
    status = -6 if sys.argv[-1] == 'create' else 1
    for module in ('moments', 'vlasov', 'gyrokinetic', 'pkpm'):
        with sqlite3.connect(root / module / 'regressiondb') as db:
            db.execute('create table RegressionMeta (guid text)')
            db.execute('create table RegressionData (guid text, name text, test_type text, status integer)')
            db.execute("insert into RegressionMeta values ('run')")
            db.execute("insert into RegressionData values ('run', ?, 'c', ?)",
                       (module + '/creg/test', status))
""")
            exe.chmod(0o755)
        result = self.run_shell(f'bash "{CI}/runregression-against-main.sh"')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Regression create: 0 completed; FAIL", result.stdout)
        self.assertIn("Regression check: 4 completed; PASS", result.stdout)
        self.assertEqual((self.root / "build/baseline-source" / manifest_path).read_text(),
                         manifest.read_text())
        logs = self.root / "logs"
        self.assertEqual(len(list(logs.glob("*-regression.sqlite"))), 8)
        summary = (logs / "summary.txt").read_text()
        self.assertIn("Regression check moments: total=1 created=0 passed=1", summary)
        self.assertIn("FAIL runregression", summary)

    def test_all_stages_attempted_after_prepare_and_install_fail(self):
        # Copy the real driver; stub only expensive stage implementations.
        scripts = self.root / "checkout/ci"
        scripts.mkdir(parents=True)
        for name in ("run.sh", "common.sh", "report-warnings.py"):
            shutil.copy(CI / name, scripts / name)
        (scripts / "prepare.sh").write_text("exit 3\n")
        for name in ("make-module.sh", "make-check.sh", "make-valcheck.sh",
                     "runregression-against-main.sh"):
            (scripts / name).write_text(
                'echo "${0##*/} $*" >> "$CI_LOG_DIR/attempts.txt"\n')
        # There is intentionally no source directory: install must fail too.
        result = self.run_shell(f'bash "{scripts}/run.sh"')
        self.assertEqual(result.returncode, 1, result.stderr)
        attempts = (self.root / "logs/attempts.txt").read_text().splitlines()
        self.assertEqual(len(attempts), 21)
        self.assertEqual(attempts[-1], "runregression-against-main.sh ")
        summary = (self.root / "logs/summary.txt").read_text()
        self.assertIn("FAIL prepare", summary)
        self.assertIn("FAIL install", summary)


if __name__ == "__main__":
    unittest.main()
