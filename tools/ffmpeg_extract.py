#!/usr/bin/env python3
"""Copies a configured FFmpeg tree's outputs into an oracle directory for tools/check_config.py.

usage: ffmpeg_extract.py <configured-build-dir> <out-dir>

Reads `make -n V=1` in a tree configured by tools/ffmpeg_configure.sh. Writes the config and
component headers and lists configure generated, and sources.txt: every source each library
compiles (with the extra include dirs its Makefile adds) and every header it installs, in the
format build/ffmpeg.zig installs to share/ffmpeg-zig/config/sources.txt.
"""
import os
import re
import shlex
import shutil
import subprocess
import sys

LIBS = ["libavutil", "libswresample", "libswscale", "libavcodec", "libavformat", "libavfilter", "libavdevice"]

ORACLE = [
    "config.h",
    "config.asm",
    "libavutil/avconfig.h",
    "config_components.h",
    "config_components.asm",
    "libavutil/ffversion.h",
    "libavcodec/bsf_list.c",
    "libavcodec/codec_list.c",
    "libavcodec/parser_list.c",
    "libavdevice/indev_list.c",
    "libavdevice/outdev_list.c",
    "libavfilter/filter_list.c",
    "libavformat/demuxer_list.c",
    "libavformat/muxer_list.c",
    "libavformat/protocol_list.c",
]


def scrub_configuration(text):
    """Replaces the machine-local tool and prefix paths in FFMPEG_CONFIGURATION with placeholders."""
    def scrub(m):
        line = re.sub(r"/[^ ']*/(tools/(?:cc|c\+\+|ar|ranlib))", r"<build>/\1", m.group(0))
        return re.sub(r"(-[IL])/[^ ']*/(include|lib)\b", r"\1<prefix>/\2", line)

    return re.sub(r"^#define FFMPEG_CONFIGURATION .*$", scrub, text, flags=re.M)


def source_of(tokens):
    for t in reversed(tokens):
        if t.startswith("src/"):
            return t[len("src/"):]
    return None


def source_includes(tokens, src_root):
    """Include dirs inside the FFmpeg tree beyond the build and source roots, relative to it."""
    dirs = []
    for t in tokens:
        if t.startswith("-I"):
            d = os.path.realpath(t[2:])
            if d.startswith(src_root + "/"):
                dirs.append(os.path.relpath(d, src_root))
    return tuple(dirs)


def main():
    bld, out = os.path.realpath(sys.argv[1]), sys.argv[2]
    src_root = os.path.realpath(os.path.join(bld, "src"))
    plan = subprocess.run(["make", "-n", "V=1"], cwd=bld, capture_output=True, text=True, check=True).stdout
    sources = {lib: {"c": {}, "nasm": set(), "gas": set(), "cuda": set(), "headers": set()} for lib in LIBS}
    for line in plan.splitlines():
        if " -o " not in line:
            continue
        tokens = shlex.split(line)
        obj = tokens[tokens.index("-o") + 1]
        lib = obj.split("/")[0]
        if lib not in sources:
            continue
        src = source_of(tokens)
        if src is None:
            continue
        if src.endswith(".cu"):
            sources[lib]["cuda"].add(src)
        elif src.endswith(".asm"):
            sources[lib]["nasm"].add(src)
        elif src.endswith(".S"):
            sources[lib]["gas"].add(src)
        elif src.endswith(".c") and "-c" in tokens:
            sources[lib]["c"].setdefault(source_includes(tokens, src_root), set()).add(src)

    for rel in ORACLE:
        if not os.path.exists(os.path.join(bld, rel)):
            continue
        dst = os.path.join(out, rel)
        os.makedirs(os.path.dirname(dst) or out, exist_ok=True)
        if rel == "config.h":
            with open(os.path.join(bld, rel), newline="") as f:
                text = f.read()
            with open(dst, "w", newline="") as f:
                f.write(scrub_configuration(text))
        else:
            shutil.copyfile(os.path.join(bld, rel), dst)

    install = subprocess.run(["make", "-n", "install"], cwd=bld, capture_output=True, text=True, check=True).stdout
    for line in install.splitlines():
        for cmd in line.split(";"):
            tokens = shlex.split(cmd)
            if tokens[:3] != ["install", "-m", "644"] or not tokens[-1].endswith(tuple("/include/" + l for l in LIBS)):
                continue
            lib = os.path.basename(tokens[-1])
            for h in tokens[3:-1]:
                if h.endswith(".h"):
                    sources[lib]["headers"].add(os.path.basename(h))

    lines = []
    for lib in LIBS:
        name = lib[3:]
        for inc, files in sources[lib]["c"].items():
            lines += [f"{name} c {','.join(inc) or '-'} {f}" for f in files]
        for kind in ("nasm", "gas", "cuda"):
            lines += [f"{name} {kind} - {f}" for f in sources[lib][kind]]
        lines += [f"{name} header - {h}" for h in sources[lib]["headers"]]
    with open(os.path.join(out, "sources.txt"), "w") as f:
        f.write("".join(line + "\n" for line in sorted(lines)))
    print(f"wrote {out}: {len(lines)} sources and headers")


if __name__ == "__main__":
    main()
