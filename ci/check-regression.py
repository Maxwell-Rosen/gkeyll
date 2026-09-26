#!/usr/bin/env python3
"""Turn runregression SQLite results into an exit status and named failures."""
from pathlib import Path
from collections import Counter
import sqlite3
import sys


def check(root, mode):
    failed, completed = False, 0
    statuses = {-6: "crash", -5: "no output", -4: "compile failed", -3: "timeout",
                -2: "created", -1: "skipped", 0: "different", 1: "passed"}
    allowed = {-2, -1, 1} if mode == "create" else {-1, 1}
    for module in ("moments", "vlasov", "gyrokinetic", "pkpm"):
        path = root / module / "regressiondb"
        try:
            with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
                latest = db.execute("select guid from RegressionMeta order by rowid desc limit 1").fetchone()
                # Some layers legitimately have no enabled tests in the manifests.
                if latest is None:
                    print(f"No selected regressions: {module}")
                    continue
                rows = db.execute("select name, test_type, status from RegressionData where guid=?", latest).fetchall()
                if not rows:
                    raise ValueError("latest run has no results")
                counts = Counter(status for _, _, status in rows)
                print(f"Regression {mode} {module}: total={len(rows)} "
                      f"created={counts[-2]} passed={counts[1]} skipped={counts[-1]} "
                      f"failed={sum(count for status, count in counts.items() if status not in allowed)}")
                for name, kind, status in rows:
                    completed += status in {-2, 1}
                    if status not in allowed:
                        label = name if name.startswith(module + "/") else f"{module}/{name}"
                        print(f"REGRESSION FAIL {label} ({kind}): {statuses.get(status, status)}")
                        failed = True
        except (sqlite3.Error, ValueError) as error:
            print(f"REGRESSION FAIL {module}: {error}")
            failed = True
    if not completed:
        print("REGRESSION FAIL: no tests completed successfully")
        failed = True
    print(f"Regression {mode}: {completed} completed; {'FAIL' if failed else 'PASS'}")
    return int(failed)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[2] not in {"create", "check"}:
        sys.exit("Usage: check-regression.py RESULTS_DIR create|check")
    sys.exit(check(Path(sys.argv[1]).resolve(), sys.argv[2]))
