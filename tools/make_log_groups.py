#!/usr/bin/env python3
"""Group the compile and nasm commands of a `make V=1` log by their ISA flags.

usage: make_log_groups.py <make-v1.log> <source_root>

For make-driven builds that emit no compile_commands.json (libvpx). Prints each distinct
set of defines and -m flags, then the source-relative files compiled with it. Dependency
generation (-M) lines, warnings, optimization and output flags are ignored.
"""
import os
import re
import shlex
import sys
from collections import defaultdict


def main():
    log, root = sys.argv[1], os.path.realpath(sys.argv[2])
    groups = defaultdict(list)
    for line in open(log):
        line = line.strip()
        if not re.match(r"^(gcc|g\+\+|cc|c\+\+|nasm|yasm)\s", line):
            continue
        args = shlex.split(line)
        if "-M" in args or "-MM" in args:
            continue
        tool = args[0]
        out = None
        src = None
        kept = []
        it = iter(args[1:])
        for a in it:
            if a == "-o":
                out = next(it)
            elif a == "-f":
                kept.append("-f " + next(it))
            elif a.startswith(("-m", "-D", "-U")) and not a.startswith("-Wl"):
                kept.append(a)
            elif a.startswith("-std="):
                kept.append(a)
            elif a == "-c" or a.startswith(("-W", "-O", "-I", "-fPIC", "-f", "-g", "-pipe")):
                continue
            elif os.path.realpath(a).startswith(root) and os.path.isfile(a):
                src = os.path.relpath(os.path.realpath(a), root)
        if src is None or out is None:
            continue
        kind = "asm" if tool in ("nasm", "yasm") else ("c++" if tool in ("g++", "c++") else "c")
        groups[(kind, tuple(sorted(set(kept))))].append(src)
    for (kind, flags), files in sorted(groups.items(), key=lambda kv: (kv[0][0], -len(kv[1]))):
        print(f"## {kind} {len(files)} files: {' '.join(flags) or '(no extra flags)'}")
        for f in sorted(files):
            print(f"  {f}")


if __name__ == "__main__":
    main()
