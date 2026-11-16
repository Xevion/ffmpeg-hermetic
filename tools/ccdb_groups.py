#!/usr/bin/env python3
"""Group a compile_commands.json by the flags that matter to a port.

usage: ccdb_groups.py <compile_commands.json> <source_root> [path-filter-regex]

Prints each distinct set of defines, -m target flags and source-relative include dirs,
followed by the source files compiled with it. Warnings, optimization, debug and output
flags are dropped because the zig build sets those itself.
"""
import json
import os
import re
import shlex
import sys
from collections import defaultdict

DROP_PREFIXES = ("-W", "-O", "-g", "-o", "-c", "-M", "-pipe", "-std=", "-fdiagnostics", "-fPIC", "-fpic", "-pthread")


def main():
    db_path, src_root = sys.argv[1], os.path.realpath(sys.argv[2])
    path_filter = re.compile(sys.argv[3]) if len(sys.argv) > 3 else None
    build_dir = os.path.dirname(os.path.realpath(db_path))
    groups = defaultdict(list)
    for entry in json.load(open(db_path)):
        args = entry.get("arguments") or shlex.split(entry["command"])
        cwd = entry["directory"]
        src = os.path.realpath(os.path.join(cwd, entry["file"]))
        rel = os.path.relpath(src, src_root) if src.startswith(src_root) else src
        if path_filter and not path_filter.search(rel):
            continue
        kept = []
        it = iter(args[1:])
        for a in it:
            if a in ("-o", "-MF", "-MQ", "-MT"):
                next(it, None)
                continue
            if a == "-I" or a == "-isystem":
                a = a + next(it)
            if a.startswith(("-I", "-isystem")):
                flag = "-I" if a.startswith("-I") else "-isystem"
                d = os.path.realpath(os.path.join(cwd, a[len(flag):]))
                if d.startswith(src_root):
                    kept.append(f"{flag}<src>/{os.path.relpath(d, src_root)}")
                elif d.startswith(build_dir):
                    kept.append(f"{flag}<build>/{os.path.relpath(d, build_dir)}")
                continue
            if a.startswith(DROP_PREFIXES) or os.path.realpath(os.path.join(cwd, a)) == src:
                continue
            if a.startswith(("-D", "-U", "-m", "-f", "-include", "-x")):
                kept.append(a)
        groups[tuple(sorted(set(kept)))].append(rel)
    for flags, files in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        print(f"## {len(files)} files: {' '.join(flags) or '(no extra flags)'}")
        for f in sorted(files):
            print(f"  {f}")


if __name__ == "__main__":
    main()
