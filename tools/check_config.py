#!/usr/bin/env python3
"""Compares the build's computed FFmpeg configuration against configure's output.

usage: check_config.py <computed-dir> <oracle-dir>

The computed dir is <prefix>/share/ffmpeg-zig/config; the oracle dir is what
tools/ffmpeg_extract.py wrote. config.h, config.asm and libavutil/avconfig.h are compared value
by value, ignoring ALLOWED, the keys this build sets differently on purpose. Every other oracle
file (component headers and lists, sources.txt) must match line for line. Exits 1 on any
difference.
"""
import difflib
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
            # Include guards (`FFMPEG_CONFIG_H`) have no value; HAVE_FOO_H keys do.
            if m and not (m.group(1).endswith("_H") and m.group(2) is None):
                values[m.group(1)] = (m.group(2) or "").strip()
    return values


HEADERS = ("config.h", "config.asm", "libavutil/avconfig.h")


def compare_lines(computed, oracle, rel):
    a_path, b_path = os.path.join(computed, rel), os.path.join(oracle, rel)
    if not os.path.exists(a_path):
        print(f"{rel}: not computed")
        return 1
    a, b = open(a_path).read().splitlines(), open(b_path).read().splitlines()
    diff = [d for d in difflib.unified_diff(b, a, "configure", "computed", lineterm="", n=0) if d[:1] in "+-" and d[:3] not in ("+++", "---")]
    for d in diff[:20]:
        print(f"{rel}: {d}")
    if len(diff) > 20:
        print(f"{rel}: ... {len(diff) - 20} more")
    return len(diff)


def main():
    computed, oracle = sys.argv[1], sys.argv[2]
    bad = 0
    for root, _, files in os.walk(oracle):
        for f in sorted(files):
            rel = os.path.relpath(os.path.join(root, f), oracle)
            if rel not in HEADERS:
                bad += compare_lines(computed, oracle, rel)
    for rel in ("config_components.asm", "config.asm"):
        if os.path.exists(os.path.join(computed, rel)) != os.path.exists(os.path.join(oracle, rel)):
            print(f"{rel}: present in only one of the two")
            bad += 1
    for rel in HEADERS:
        if not os.path.exists(os.path.join(oracle, rel)):
            continue
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
