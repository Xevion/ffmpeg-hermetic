#!/usr/bin/env python3
"""Compares computed config headers against configure's output, value by value.

usage: check_config.py <computed-dir> <oracle-dir>

Each directory holds config.h, config.asm and libavutil/avconfig.h. Exits 1 on any difference
outside ALLOWED, the keys this build sets differently from configure on purpose.
"""
import os
import re
import sys

ALLOWED = {
    # configure finds sysctl() in zig's libc stubs, but zig ships no <sys/sysctl.h>.
    "HAVE_SYSCTL",
    # Strings that name the configure invocation and compiler rather than the build's behavior.
    "FFMPEG_CONFIGURATION",
    "CC_IDENT",
}

DEFINE = re.compile(r"^\s*[#%]define\s+(\w+)(?:\s+(.*?))?\s*$")


def parse(path):
    values = {}
    with open(path) as f:
        for line in f:
            m = DEFINE.match(line)
            if m and not m.group(1).endswith("_H"):
                values[m.group(1)] = (m.group(2) or "").strip()
    return values


def main():
    computed, oracle = sys.argv[1], sys.argv[2]
    bad = 0
    for rel in ("config.h", "config.asm", "libavutil/avconfig.h"):
        a, b = parse(os.path.join(computed, rel)), parse(os.path.join(oracle, rel))
        for key in sorted(a.keys() | b.keys()):
            if key in ALLOWED:
                continue
            if a.get(key) != b.get(key):
                print(f"{rel}: {key}: computed {a.get(key)!r}, configure {b.get(key)!r}")
                bad += 1
    print(f"{bad} difference(s)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
