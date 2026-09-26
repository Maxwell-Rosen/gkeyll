#!/usr/bin/env python3
"""Overlay the local working tree on a private clone, excluding ignored build artifacts."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

source, destination = map(Path, sys.argv[1:])
files = subprocess.check_output(
    ["git", "-C", str(source), "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
)
for name in set(files.split(b"\0")) - {b""}:
    relative = Path(os.fsdecode(name))
    src, dst = source / relative, destination / relative
    if dst.is_symlink() or dst.is_file():
        dst.unlink()
    if src.is_symlink():
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.symlink_to(os.readlink(src))
    elif src.is_file():
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
