#!/usr/bin/env python3
"""Summarize compiler diagnostics without turning warnings into failures."""

import argparse
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--github", action="store_true")
    parser.add_argument("logs", nargs="*")
    args = parser.parse_args()
    # GCC/Clang, Intel and NVCC (including numbered warning diagnostics).
    warning = re.compile(r"\bwarning(?:\s+#[\w-]+)?\s*:", re.IGNORECASE)
    ansi = re.compile(r"\x1b\[[0-9;]*m")
    diagnostics = {}
    count = 0
    for name in args.logs:
        path = Path(name)
        if not path.is_file():
            continue
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            line = ansi.sub("", line)
            if warning.search(line):
                count += 1
                if line not in diagnostics:
                    diagnostics[line] = [f"{name}:{number}", 0]
                diagnostics[line][1] += 1
    summary = f"Compiler warnings: {count} (informational; do not fail CI)\n"
    for line, (location, occurrences) in diagnostics.items():
        repeated = f" [repeated {occurrences} times; first occurrence]" if occurrences > 1 else ""
        summary += f"{location}: {line}{repeated}\n"
    Path(args.output).write_text(summary)
    print(summary, end="")
    if args.github and diagnostics:
        # A bounded annotation points to the full report in the summary/artifact.
        message = f"{count} compiler warning(s); see {args.output} in CI logs and the job summary."
        message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::warning title=Compiler warnings::{message}")


if __name__ == "__main__":
    main()
