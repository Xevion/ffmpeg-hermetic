#!/usr/bin/env python3
"""Lays out a build tree in which FFmpeg's own `make fate` runs against this build's binaries.

usage: fate_tree.py <ffmpeg-src> <prefix> <tree> <zig-target>

<prefix> is an install prefix of `zig build -Dprograms=true`. The tree gets this build's
generated config headers and component lists, an ffbuild/config.mak derived from them (every
ARCH_, HAVE_ and CONFIG_ name configure would print), links to the built ffmpeg and ffprobe and
to the library archives, and a Makefile that includes FFmpeg's. The test programs, which make
compiles itself, are compiled with `zig cc` and linked against the archives; make is run with
`-o` on everything this tree provides so none of it is rebuilt (see tools/fate.sh).
"""
import glob
import os
import re
import shutil
import sys

LIBS = ["avutil", "swresample", "swscale", "avcodec", "avformat", "avfilter", "avdevice"]
DEFINE = re.compile(r"^#define\s+((?:ARCH|HAVE|CONFIG)_\w+)\s+([01])\s*$")
ARCHES = {"x86": "x86", "aarch64": "aarch64"}


def fail(msg):
    sys.exit(f"fate_tree.py: {msg}")


def config_names(path):
    names = {}
    for line in open(path):
        m = DEFINE.match(line)
        if m:
            names[m.group(1)] = m.group(2) == "1"
    return names


def main():
    if len(sys.argv) != 5:
        fail("usage: fate_tree.py <ffmpeg-src> <prefix> <tree> <zig-target>")
    src, prefix, tree, target = (os.path.realpath(a) if i < 3 else a for i, a in enumerate(sys.argv[1:]))
    cfg = os.path.join(prefix, "share/ffmpeg-hermetic/config")
    for need in (os.path.join(cfg, "config.h"), os.path.join(prefix, "bin/ffmpeg"), os.path.join(prefix, "bin/ffprobe")):
        if not os.path.exists(need):
            fail(f"{need} is missing; build with -Dprograms=true and install into {prefix}")

    os.makedirs(os.path.join(tree, "ffbuild"), exist_ok=True)
    for entry in os.listdir(cfg):
        if entry == "sources.txt":
            continue
        dst = os.path.join(tree, entry)
        if os.path.isdir(os.path.join(cfg, entry)):
            shutil.copytree(os.path.join(cfg, entry), dst, dirs_exist_ok=True)
        else:
            shutil.copy(os.path.join(cfg, entry), dst)

    names = config_names(os.path.join(cfg, "config.h"))
    names.update(config_names(os.path.join(cfg, "config_components.h")))
    arch = next((v for k, v in ARCHES.items() if names.get(f"ARCH_{k.upper()}")), None)
    if arch is None:
        fail("only x86 and aarch64 builds are supported")
    intrinsics = "none"
    for name, on in names.items():
        if on and name.startswith("HAVE_INTRINSICS_"):
            intrinsics = name[len("HAVE_INTRINSICS_"):].lower()
    # configure lists the programs in CONFIG_LIST; this build's config.h has them off.
    names.update({"CONFIG_FFMPEG": True, "CONFIG_FFPROBE": True, "CONFIG_FFPLAY": False})

    externals = sorted(
        os.path.basename(p)[3:-2]
        for p in glob.glob(os.path.join(prefix, "lib/lib*.a"))
        if not re.match(r"lib(av|sw)", os.path.basename(p)) and not p.endswith("_headers.a")
    )
    extralibs = f"-L{prefix}/lib " + " ".join(f"-l{n}" for n in externals) + " -lc++ -lm -lpthread -ldl"

    lines = [
        "# Written by tools/fate_tree.py from this build's config headers.",
        "ifndef FFMPEG_CONFIG_MAK",
        "FFMPEG_CONFIG_MAK=1",
        "prefix=/usr/local",
        "LIBDIR=$(DESTDIR)${prefix}/lib",
        "SHLIBDIR=$(DESTDIR)${prefix}/lib",
        "INCDIR=$(DESTDIR)${prefix}/include",
        "BINDIR=$(DESTDIR)${prefix}/bin",
        "DATADIR=$(DESTDIR)${prefix}/share/ffmpeg",
        "DOCDIR=$(DESTDIR)${prefix}/share/doc/ffmpeg",
        "MANDIR=$(DESTDIR)${prefix}/share/man",
        "PKGCONFIGDIR=$(DESTDIR)${prefix}/lib/pkgconfig",
        "INSTALL_NAME_DIR=",
        f"SRC_PATH={src}",
        "SRC_LINK=src",
        "ifndef MAIN_MAKEFILE",
        "SRC_PATH:=$(SRC_PATH:.%=..%)",
        "endif",
        f"ARCH={arch}",
        f"INTRINSICS={intrinsics}",
        f"CC=zig cc -target {target} -fno-sanitize=undefined -g0",
        f"CXX=zig c++ -target {target} -fno-sanitize=undefined -g0",
        f"AS=zig cc -target {target} -fno-sanitize=undefined -g0",
        f"LD=zig cc -target {target}",
        "DEPCC=$(CC)",
        "DEPCCFLAGS=$(CPPFLAGS)",
        "DEPAS=$(AS)",
        "DEPASFLAGS=$(CPPFLAGS)",
        "X86ASM=nasm",
        "DEPX86ASM=nasm",
        "DEPX86ASMFLAGS=$(X86ASMFLAGS)",
        "X86ASMFLAGS=-f elf64",
        "AR=zig ar",
        "ARFLAGS=rcD",
        "AR_O=$@",
        "AR_CMD=zig ar",
        "RANLIB=zig ranlib -D",
        "NM_CMD=nm -g",
        "STRIP=strip",
        "CP=cp -p",
        "LN_S=ln -s -f",
        "CPPFLAGS= -D_ISOC11_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_POSIX_C_SOURCE=200112 -D_XOPEN_SOURCE=600 -DPIC -DZLIB_CONST",
        f"CFLAGS= -std=c17 -fomit-frame-pointer -fPIC -O2 -fno-math-errno -fno-signed-zeros -mstack-alignment=16 -Qunused-arguments -Werror=implicit-function-declaration -isystem {prefix}/include",
        "CXXFLAGS= -std=c++17 -fPIC -O2 -Qunused-arguments",
        "ASFLAGS= -fPIC -Qunused-arguments",
        "AS_C=-c",
        "AS_O=-o $@",
        "CC_C=-c",
        "CC_E=-E -o $@",
        "CC_O=-o $@",
        "CXX_C=-c",
        "CXX_O=-o $@",
        "LD_O=-o $@",
        "X86ASM_O=-o $@",
        "LD_LIB=-l%",
        "LD_PATH=-L",
        "LDFLAGS= -Wl,-z,noexecstack",
        "LDEXEFLAGS=",
        "CCDEP=",
        "CXXDEP=",
        "ASDEP=",
        "CCDEP_FLAGS=",
        "CXXDEP_FLAGS=",
        "ASDEP_FLAGS=",
        "CC_DEPFLAGS=-MMD -MF $(@:.o=.d) -MT $@",
        "CXX_DEPFLAGS=-MMD -MF $(@:.o=.d) -MT $@",
        "AS_DEPFLAGS=-MMD -MF $(@:.o=.d) -MT $@",
        "X86ASM_DEPFLAGS=-MD $(@:.o=.d)",
        "ASMSTRIPFLAGS= -x",
        "BUILDSUF=",
        "PROGSSUF=",
        "FULLNAME=$(NAME)$(BUILDSUF)",
        "LIBPREF=lib",
        "LIBSUF=.a",
        "LIBNAME=$(LIBPREF)$(FULLNAME)$(LIBSUF)",
        "SLIBPREF=lib",
        "SLIBSUF=.so",
        "EXESUF=",
        "EXTRA_VERSION=",
        "HOSTCC=zig cc",
        "HOSTLD=zig cc",
        "HOSTCFLAGS= -std=c17 -O2",
        "HOSTCPPFLAGS= -D_ISOC11_SOURCE -D_POSIX_C_SOURCE=200112 -D_XOPEN_SOURCE=600",
        "HOSTEXESUF=",
        "HOSTLDFLAGS=",
        "HOSTEXTRALIBS=-lm",
        "DEPHOSTCC=$(HOSTCC)",
        "DEPHOSTCCFLAGS= $(HOSTCCFLAGS)",
        "HOSTCCDEP=",
        "HOSTCCDEP_FLAGS=",
        "HOSTCC_DEPFLAGS=-MMD -MF $(@:.o=.d) -MT $@",
        "HOSTCC_C=-c",
        "HOSTCC_O=-o $@",
        "HOSTLD_O=-o $@",
        "TARGET_EXEC=$(FATE_TARGET_EXEC)",
        "TARGET_PATH=$(CURDIR)",
        "TARGET_SAMPLES=$(SAMPLES)",
        "SAMPLES:=$(FATE_SAMPLES)",
        "IGNORE_TESTS=",
        "VERSION_TRACKING=yes",
        "INSTALL=install",
        "COMPAT_OBJS=",
        "SLIBNAME=$(SLIBPREF)$(FULLNAME)$(SLIBSUF)",
        "SLIBNAME_WITH_VERSION=$(SLIBNAME).$(LIBVERSION)",
        "SLIBNAME_WITH_MAJOR=$(SLIBNAME).$(LIBMAJOR)",
        "SLIB_INSTALL_NAME=$(SLIBNAME_WITH_VERSION)",
        "SLIB_INSTALL_LINKS=$(SLIBNAME_WITH_MAJOR) $(SLIBNAME)",
        "VERSION_SCRIPT_POSTPROCESS_CMD=cat",
        "RESPONSE_FILES=yes",
        "EXTRALIBS=",
    ]
    fflibs = {
        "avutil": [],
        "swresample": ["avutil"],
        "swscale": ["avutil"],
        "avcodec": ["swresample", "avutil"],
        "avformat": ["avcodec", "swresample", "avutil"],
        "avfilter": ["swscale", "avformat", "avcodec", "swresample", "avutil"],
        "avdevice": ["avfilter", "swscale", "avformat", "avcodec", "swresample", "avutil"],
    }
    for lib, deps in fflibs.items():
        lines.append(f"{lib}_FFLIBS={' '.join(deps)}")
        lines.append(f"EXTRALIBS-{lib}={extralibs}")
    for prog in ("ffplay", "ffprobe", "ffmpeg", "cpu_init", "cws2fws"):
        lines.append(f"EXTRALIBS-{prog}={extralibs}")
    for name in sorted(names):
        lines.append(f"{name}=yes" if names[name] else f"!{name}=yes")
    lines.append("endif")
    with open(os.path.join(tree, "ffbuild/config.mak"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(tree, "Makefile"), "w") as f:
        f.write(f"include {src}/Makefile\n")

    link(src, os.path.join(tree, "src"))
    for tool in ("ffmpeg", "ffprobe"):
        link(os.path.join(prefix, "bin", tool), os.path.join(tree, tool))
    for lib in LIBS:
        os.makedirs(os.path.join(tree, f"lib{lib}"), exist_ok=True)
        link(os.path.join(prefix, f"lib/lib{lib}.a"), os.path.join(tree, f"lib{lib}/lib{lib}.a"))


def link(target, path):
    if os.path.lexists(path):
        os.remove(path)
    os.symlink(target, path)


if __name__ == "__main__":
    main()
