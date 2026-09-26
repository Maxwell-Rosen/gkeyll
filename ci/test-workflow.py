#!/usr/bin/env python3
"""Exercise CI reporting and failure propagation without building Gkeyll."""

import os
from pathlib import Path
import shutil
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

    def test_error_with_warning_keeps_exit_status(self):
        result = self.run_shell(
            f'source "{CI}/common.sh"; '
            "ci_log compile bash -c 'echo warning: example; exit 7'")
        self.assertEqual(result.returncode, 7, result.stderr)
        summary = (self.root / "logs/summary.txt").read_text()
        self.assertIn("FAIL compile (exit 7)", summary)
        self.assertIn("Compiler warnings: 1", summary)

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
