#!/usr/bin/env python3
"""Package one immutable task range for a read-only reviewer."""
from pathlib import Path
import subprocess
import sys

repo, base, head, output = sys.argv[1:]
parts = [f"Repository: {repo}\nBase: {base}\nHead: {head}\n"]
for label, args in (
    ("Commits", ["log", "--oneline", f"{base}..{head}"]),
    ("Stat", ["diff", "--no-ext-diff", "--stat", base, head]),
    ("Diff", ["diff", "--no-ext-diff", "--find-renames", "-U12", base, head]),
):
    value = subprocess.check_output(["git", "-C", repo, *args])
    parts.append(f"\n## {label}\n\n" + value.decode("utf-8", errors="backslashreplace"))
path = Path(output)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("".join(parts))
print(path)
