#!/usr/bin/env python3
"""Generates gen/ffmpeg/<major.minor>/configure.zig from FFmpeg's configure script and Makefiles.

usage: ffmpeg_gen.py <ffmpeg-src> <out.zig>

Runs the declaration and option-parsing part of configure in bash (no compiler, no probes) with
the base options this build uses, then records configure's lists, every `*_deps`-style
declaration, and the state check_deps starts from. Parses each library's Makefile, arch Makefiles
and ffbuild/arch.mak into objects with the conditions that enable them. build/ffmpeg/ resolves
both at build-graph time for a target and a set of external libraries.
"""
import os
import re
import subprocess
import sys
import tempfile

# Options from tools/ffmpeg_configure.sh that are not external libraries or toolchain paths.
BASE_FLAGS = [
    "--enable-static", "--disable-shared", "--enable-pic", "--disable-programs", "--disable-doc",
    "--disable-debug", "--disable-autodetect", "--enable-runtime-cpudetect", "--enable-network",
    "--enable-pixelutils",
]

LIBS = ["libavutil", "libswresample", "libswscale", "libavcodec", "libavformat", "libavfilter", "libavdevice"]

DEP_KINDS = ["deps", "deps_any", "conflict", "select", "suggest", "if", "if_any"]

OPTS_END = "enable_weak $HWACCEL_AUTODETECT_LIBRARY_LIST"

LISTS = [
    "CONFIG_LIST", "CONFIG_EXTRA", "HAVE_LIST", "ARCH_LIST", "ALL_COMPONENTS", "HAVE_LIST_PUB",
    "EXTERNAL_LIBRARY_LIST", "HWACCEL_LIBRARY_LIST", "EXTERNAL_AUTODETECT_LIBRARY_LIST",
    "HWACCEL_AUTODETECT_LIBRARY_LIST", "INTRINSICS_LIST", "EXTERNAL_LIBRARY_GPL_LIST",
    "EXTERNAL_LIBRARY_NONFREE_LIST", "EXTERNAL_LIBRARY_VERSION3_LIST", "EXTERNAL_LIBRARY_GPLV3_LIST",
    "HWACCEL_LIBRARY_NONFREE_LIST",
    "FILTER_LIST", "CODEC_LIST", "PARSER_LIST", "BSF_LIST", "DEMUXER_LIST", "MUXER_LIST",
    "INDEV_LIST", "OUTDEV_LIST", "PROTOCOL_LIST",
]

# print_enabled_components calls at the end of configure, in order.
COMPONENT_FILES = [
    ("libavfilter/filter_list.c", "FFFilter", "filter_list", "FILTER_LIST"),
    ("libavcodec/codec_list.c", "FFCodec", "codec_list", "CODEC_LIST"),
    ("libavcodec/parser_list.c", "FFCodecParser", "parser_list", "PARSER_LIST"),
    ("libavcodec/bsf_list.c", "FFBitStreamFilter", "bitstream_filters", "BSF_LIST"),
    ("libavformat/demuxer_list.c", "FFInputFormat", "demuxer_list", "DEMUXER_LIST"),
    ("libavformat/muxer_list.c", "FFOutputFormat", "muxer_list", "MUXER_LIST"),
    ("libavdevice/indev_list.c", "FFInputFormat", "indev_list", "INDEV_LIST"),
    ("libavdevice/outdev_list.c", "FFOutputFormat", "outdev_list", "OUTDEV_LIST"),
    ("libavformat/protocol_list.c", "URLProtocol", "url_protocols", "PROTOCOL_LIST"),
]
FILTER_TAIL = ["asrc_abuffer", "vsrc_buffer", "asink_abuffer", "vsink_buffer"]


def fail(msg):
    sys.exit(f"ffmpeg_gen.py: {msg}")


def configure_state(src):
    configure = os.path.join(os.path.realpath(src), "configure")
    text = open(configure).read()
    if f"\n{OPTS_END}\n" not in text:
        fail(f"configure no longer has the line {OPTS_END!r}")
    head = text[: text.index(f"\n{OPTS_END}\n") + len(OPTS_END) + 2]
    for needle in ("check_deps $CONFIG_LIST", "for c in " + " ".join(FILTER_TAIL) + "; do"):
        if needle not in text:
            fail(f"configure no longer contains {needle!r}")
    dump = 'for v in $(compgen -v); do printf "%s\\0%s\\0" "$v" "${!v}"; done'
    with tempfile.TemporaryDirectory() as tmp:
        script = os.path.join(tmp, "head.sh")
        with open(script, "w") as f:
            f.write(head)
        out = subprocess.run(
            ["bash", "-c", f'source "{script}" "$@" >/dev/null || exit 1; {dump}', configure, *BASE_FLAGS],
            cwd=tmp, capture_output=True, check=True,
        ).stdout.decode()
    parts = out.split("\0")
    return dict(zip(parts[0::2], parts[1::2]))


def configure_data(src):
    v = configure_state(src)
    lists = {name: v[name].split() for name in LISTS}
    # libavcodec's *_tablegen host programs only matter when tables are compiled in.
    if v.get("hardcoded_tables", "") not in ("", "no"):
        fail("hardcoded_tables is not off, so libavcodec's table generators would be needed")
    start = set()
    for name in ("CONFIG_LIST", "CONFIG_EXTRA", "HAVE_LIST", "ALL_COMPONENTS", "ARCH_LIST"):
        start.update(lists[name])
    decls = {}
    seen, todo = set(start), list(start)
    while todo:
        name = todo.pop()
        d = {}
        for kind in DEP_KINDS:
            items = v.get(f"{name}_{kind}", "").split()
            if items:
                d[kind] = items
        if d:
            decls[name] = d
        for items in d.values():
            for dep in items:
                if dep.startswith("!"):
                    fail(f"{name} has a negated dependency {dep}; check_deps does not handle these")
                if dep not in seen:
                    seen.add(dep)
                    todo.append(dep)
    defaults = {n: v[n] for n in sorted(seen) if v.get(n, "") in ("yes", "no")}
    odd = {n: v[n] for n in seen if v.get(n, "") not in ("", "yes", "no")}
    if odd:
        fail(f"names with values other than yes/no/unset: {sorted(odd)[:5]}")

    filters = {}
    allfilters = open(os.path.join(src, "libavfilter/allfilters.c")).read()
    for m in re.finditer(r"^extern const FFFilter ff_([avfsinkrc]{2,5})_(.*);", allfilters, re.M):
        filters[m.group(2)] = f"{m.group(1)}_{m.group(2)}"
    files = []
    for path, struct, array, list_name in COMPONENT_FILES:
        entries = []
        for c in lists[list_name]:
            if array == "filter_list":
                sym = filters[c[: -len("_filter")]]
            elif array == "indev_list":
                sym = c[: -len("_indev")] + "_demuxer"
            elif array == "outdev_list":
                sym = c[: -len("_outdev")] + "_muxer"
            else:
                sym = c
            entries.append((c, sym))
        files.append((path, struct, array, entries))
    return lists, decls, defaults, files


PREPROCESS_RECIPE = "$(HOSTCC) $(HOSTCC_E) $(CPPFLAGS) $<"
HOSTGEN_RECIPE = ["$(M)$< {flag} > $@.tmp", "$(CP) $@.tmp $@", "$(RM) $@.tmp"]


def recipe(path, rule):
    """The tab-indented recipe lines of the rule whose first line starts with `rule`."""
    out, state = [], "outside"
    for line in open(path).read().split("\n"):
        if state == "outside":
            if line.startswith(rule):
                state = "header" if line.endswith("\\") else "body"
        elif state == "header":
            state = "header" if line.endswith("\\") else "body"
        elif line.startswith("\t"):
            out.append(line.strip())
        else:
            break
    return out


class Makefile:
    """The subset of make FFmpeg's library Makefiles use, evaluated symbolically."""

    VAR = re.compile(r"^([A-Z0-9_]+(?:-[A-Z0-9_]+)*?)(?:-\$\((!?(?:CONFIG|HAVE|ARCH)_\w+)\)|-yes)?\s*(\+?=|:=)\s*(.*)$")
    TEMPLATE = re.compile(r"^(\w+?)((?:_\$\((?:CONFIG|HAVE|ARCH)_\w+\))+)\s*=\s*(.*)$")

    def __init__(self, src, lib, gates):
        self.src, self.lib, self.gates = src, lib, gates
        self.vars = {}
        self.aux = {}
        self.templates = []
        self.includes = []
        self.preprocessed = []
        self.host_progs = []
        self.hostgen = []

    @staticmethod
    def name(key):
        neg = "!" if key.startswith("!") else ""
        return neg + key.split("_", 1)[1].lower()

    def lines(self, path):
        raw = open(path).read().split("\n")
        out, cur = [], None
        for line in raw:
            if cur is not None:
                cur += " " + line
            elif line.startswith("\t"):
                continue
            else:
                cur = line
            if cur.endswith("\\"):
                cur = cur[:-1]
                continue
            out.append(re.sub(r"#.*", "", cur).strip())
            cur = None
        return out

    def parse(self, path, scope, outer=()):
        stack = list(outer)
        for line in self.lines(path):
            if not line:
                continue
            m = re.match(r"^(ifdef|ifndef)\s+((?:CONFIG|HAVE|ARCH)_\w+)$", line)
            if m:
                stack.append(("" if m.group(1) == "ifdef" else "!") + self.name(m.group(2)))
                continue
            m = re.match(r"^ifeq\s+\(\$\(((?:CONFIG|HAVE|ARCH)_\w+)\),yes\)$", line)
            if m:
                stack.append(self.name(m.group(1)))
                continue
            if line == "else":
                c = stack.pop()
                stack.append(c[1:] if c.startswith("!") else "!" + c)
                continue
            if line == "endif":
                stack.pop()
                continue
            if line.startswith(("ifeq", "ifneq", "ifdef", "ifndef", "define")):
                fail(f"{path}: unhandled conditional {line!r}")
            m = re.match(r"^(-?)include\s+\$\(SRC_PATH\)/(\S+)$", line)
            if m:
                inc = m.group(2)
                if "$(ARCH)" in inc:
                    for arch in sorted(os.listdir(os.path.join(self.src, self.lib))):
                        p = os.path.join(self.src, inc.replace("$(ARCH)", arch))
                        if os.path.isfile(p):
                            self.parse(p, arch, stack)
                else:
                    self.parse(os.path.join(self.src, inc), scope, stack)
                continue
            m = re.match(r"^(\S+)/%\.o:\s*CPPFLAGS\s*\+=\s*-I\$\(SRC_PATH\)/(\S+?)/?$", line)
            if m:
                self.includes.append((m.group(1) + "/", m.group(2)))
                continue
            m = self.TEMPLATE.match(line)
            if m:
                keys = re.findall(r"\$\(((?:CONFIG|HAVE|ARCH)_\w+)\)", m.group(2))
                self.templates.append((m.group(1), keys, m.group(3).split(), list(stack)))
                continue
            m = re.match(r"^\$\(SUBDIR\)(\S+\.gen\.asm):\s*\$\(SRC_PATH\)/(\S+\.asm\.h)(\s.*)?$", line)
            if m:
                if recipe(path, "$(SUBDIR)" + m.group(1) + ":") != [PREPROCESS_RECIPE]:
                    fail(f"{path}: unhandled recipe for {m.group(1)}")
                self.preprocessed.append((f"{self.lib}/{m.group(1)}", m.group(2), scope))
                continue
            m = re.match(r"^\$\(SUBDIR\)(\S+\.gen\.(?:S|c)):\s*\$\(SUBDIR\)(\S+)\$\(HOSTEXESUF\)$", line)
            if m:
                target, prog = m.groups()
                lines = recipe(path, "$(SUBDIR)" + target + ":")
                flag = re.match(r"^\$\(M\)\$< (-\w+) > \$@\.tmp$", lines[0]) if lines else None
                if not flag or lines != [r.format(flag=flag.group(1)) for r in HOSTGEN_RECIPE]:
                    fail(f"{path}: unhandled recipe for {target}: {lines!r}")
                self.hostgen.append((f"{self.lib}/{target}", f"{self.lib}/{prog}", flag.group(1)))
                continue
            m = self.VAR.match(line)
            if not m:
                if ":" in line.split("=", 1)[0]:
                    if ".gen." in line.split(":", 1)[0]:
                        fail(f"{path}: unhandled rule for a generated file: {line!r}")
                    continue
                fail(f"{path}: unhandled line {line!r}")
            var, key, op, value = m.groups()
            if var == "HOSTPROGS":
                if op != "=" or key or stack:
                    fail(f"{path}: conditional HOSTPROGS {line!r}")
                self.host_progs += [f"{self.lib}/{w}" for w in value.split()]
                continue
            kept = var in self.gates or var in ("STLIBOBJS", "SHLIBOBJS", "HEADERS", "BUILT_HEADERS")
            if not kept and not var.endswith("-OBJS"):
                continue
            store = self.vars if kept else self.aux
            cond = list(stack) + ([self.name(key)] if key else [])
            if op != "+=":
                if stack or key:
                    fail(f"{path}: conditional assignment {line!r}")
                store[var] = []
            store.setdefault(var, []).extend(self.words(path, value, cond, scope))

    def words(self, path, value, cond, scope):
        out = []
        for m in re.finditer(r"\$\(if \$\(!((?:CONFIG|HAVE|ARCH)_\w+)\),\s*([^)]*)\)|\$\(([\w-]+)\)|(\S+)", value):
            if m.group(1):
                out += [(w, cond + ["!" + self.name(m.group(1))], scope) for w in m.group(2).split()]
            elif m.group(3):
                out.append(("$", m.group(3), path, cond, scope))
            elif m.group(4) == "$(COMPAT_OBJS:%=../compat/%)":
                # Target-specific replacements configure picks (msvcrt, djgpp); none on linux.
                continue
            else:
                if "$" in m.group(4):
                    fail(f"{path}: unhandled reference in {m.group(4)!r}")
                out.append((m.group(4), cond, scope))
        return out

    def expand(self, entries):
        """Resolves deferred `$(VAR)` references, as make expands recursive variables at use."""
        out = []
        for e in entries:
            if e[0] != "$":
                out.append(e)
                continue
            _, ref, path, cond, scope = e
            if ref.endswith("-yes") and ref[:-4] in self.aux:
                out += [(w, cond + c, scope) for w, c, _ in self.expand(self.aux[ref[:-4]])]
            else:
                out += self.expand_template(path, ref, cond, scope)
        return out

    def expand_template(self, path, ref, cond, scope):
        for base, keys, files, tcond in self.templates:
            if not ref.startswith(base + "_"):
                continue
            vals = ref[len(base) + 1:].split("_")
            if len(vals) != len(keys) or any(x not in ("", "yes") for x in vals):
                continue
            extra = [("" if x == "yes" else "!") + self.name(k) for k, x in zip(keys, vals)]
            return [(f, cond + tcond + extra, scope) for f in files]
        fail(f"{path}: unknown variable $({ref})")


def source_for(src, lib, obj, hostgen):
    stem = os.path.join(lib, obj[: -len(".o")])
    for ext in (".S", ".c"):
        if stem.endswith(".gen") and stem + ext in hostgen:
            return stem + ext, "hostgen"
    if obj.endswith(".ptx.o"):
        return stem[: -len(".ptx")] + ".cu", "cuda"
    for ext, kind in ((".c", "c"), (".cpp", "cpp"), (".m", "objc"), (".S", "gas"), (".asm", "nasm"), (".rc", "rc")):
        if os.path.isfile(os.path.join(src, stem + ext)):
            return stem + ext, kind
    if os.path.isfile(os.path.join(src, stem + ".cl")):
        return stem + ".cl", "opencl"
    return stem + ".o", "generated"


def makefile_data(src):
    gates = {"OBJS": None}
    for line in open(os.path.join(src, "ffbuild/arch.mak")):
        m = re.match(r"^OBJS-\$\(HAVE_(\w+)\)\s*\+=\s*\$\(([\w-]+)\)\s+\$\(\2-yes\)$", line.strip())
        if m:
            gates[m.group(2)] = m.group(1).lower()
        elif line.strip():
            fail(f"arch.mak: unhandled line {line.strip()!r}")
    libs = []
    for lib in LIBS:
        mk = Makefile(src, lib, gates)
        mk.parse(os.path.join(src, lib, "Makefile"), "")
        for sub in sorted(os.listdir(os.path.join(src, lib))):
            p = os.path.join(src, lib, sub, "Makefile")
            if os.path.isfile(p) and not any(i[0] == f"{lib}/{sub}/" for i in mk.includes) and sub not in INCLUDED[lib]:
                mk.parse(p, sub)
        objects = []
        for var, entries in mk.vars.items():
            if var in ("HEADERS", "BUILT_HEADERS", "SHLIBOBJS"):
                continue
            gate = gates.get(var)
            for obj, cond, scope in mk.expand(entries):
                if not obj.endswith(".o"):
                    fail(f"{lib}: {var} lists {obj!r}")
                path, kind = source_for(src, lib, obj, {g[0] for g in mk.hostgen})
                incs = sorted({inc for prefix, inc in mk.includes if path.startswith(prefix)})
                when = ([gate] if gate else []) + cond
                objects.append((path, kind, scope, tuple(when), tuple(incs)))
        headers = [h for h, _, _ in mk.expand(mk.vars.get("HEADERS", []))]
        built = [h for h, _, _ in mk.expand(mk.vars.get("BUILT_HEADERS", []))]
        progs = {}
        for target, prog, flag in sorted(set(mk.hostgen)):
            if prog not in mk.host_progs:
                fail(f"{lib}: {target} runs {prog}, which HOSTPROGS does not list")
            progs.setdefault(prog, []).append((flag, target))
        for prog in progs:
            if not os.path.isfile(os.path.join(src, prog + ".c")):
                fail(f"{lib}: no source for host program {prog}")
        libs.append((lib[3:], sorted(set(objects), key=lambda o: (o[0], o[2], o[3])), headers, built, sorted(set(mk.preprocessed)), sorted(progs.items())))
    return libs


def logical_lines(path):
    """Makefile lines with continuations joined, comments dropped and recipes skipped."""
    out, cur = [], None
    for line in open(path).read().split("\n"):
        if cur is not None:
            cur += " " + line
        elif line.startswith("\t"):
            continue
        else:
            cur = line
        if cur.endswith("\\"):
            cur = cur[:-1]
            continue
        out.append(re.sub(r"#.*", "", cur).strip())
        cur = None
    return [l for l in out if l]


def program_data(src):
    """fftools/Makefile's per-program sources and embedded resources, unconditional on this build."""
    objs = {}
    resman, resobjs = [], []
    common = None
    for path in ("fftools/Makefile", "fftools/resources/Makefile"):
        for line in logical_lines(os.path.join(src, path)):
            m = re.match(r"^OBJS-(ffmpeg|ffplay|ffprobe)\s*\+=\s*(.*)$", line)
            if m:
                words = m.group(2).split()
                objs.setdefault(m.group(1), []).extend(words)
                continue
            m = re.match(r"^(OBJS-resman|RESOBJS)\s*\+=\s*(.*)$", line)
            if m:
                (resman if m.group(1) == "OBJS-resman" else resobjs).extend(m.group(2).split())
                continue
            if line == "OBJS-$(1) += fftools/fftoolsres.o":
                continue  # windres version resource, Windows only
            if line.startswith("OBJS-$(1) +="):
                if line != "OBJS-$(1) += fftools/cmdutils.o fftools/opt_common.o fftools/$(1).o $(OBJS-$(1)-yes)":
                    fail(f"{path}: unhandled program object line {line!r}")
                common = ["fftools/cmdutils.o", "fftools/opt_common.o"]
            elif re.match(r"^(OBJS|RESOBJS|AVPROGS)\S*\s*(\+|:)?=", line) and not line.startswith(
                ("AVPROGS-", "AVPROGS ", "AVPROGS:")
            ):
                fail(f"{path}: unhandled line {line!r}")
    if common is None:
        fail("fftools/Makefile no longer has the DOFFTOOL object line")
    programs = []
    for name in ("ffmpeg", "ffplay", "ffprobe"):
        sources, resources = [], []
        words = common + [f"fftools/{name}.o"] + objs.get(name, [])
        for w in words:
            if w == "$(OBJS-resman)":
                words_in = resman
            elif w == "$(RESOBJS)":
                words_in = resobjs
            elif w == "$(COMPAT_OBJS:%=compat/%)":
                continue
            else:
                words_in = [w]
            for o in words_in:
                if "$" in o or not o.endswith(".o"):
                    fail(f"fftools/Makefile: unhandled object {o!r} for {name}")
                stem = o[: -len(".o")]
                if os.path.isfile(os.path.join(src, stem + ".c")):
                    sources.append(stem + ".c")
                elif os.path.isfile(os.path.join(src, stem)) and stem.endswith((".html", ".css")):
                    resources.append(stem)
                else:
                    fail(f"fftools/Makefile: no source for {o}")
        programs.append((name, sorted(set(sources)), sorted(set(resources))))
    return programs


# Subdirectories a library Makefile includes itself, which are not arch or intrinsics dirs.
INCLUDED = {lib: set() for lib in LIBS}


def find_included(src):
    for lib in LIBS:
        for line in open(os.path.join(src, lib, "Makefile")):
            m = re.match(rf"^-?include \$\(SRC_PATH\)/{lib}/(\w+)/Makefile", line)
            if m:
                INCLUDED[lib].add(m.group(1))


ZIG_FIELD = {"if": '@"if"'}


def zstr(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def zlist(items):
    return "&.{" + ", ".join(zstr(i) for i in items) + "}"


def write(out, lists, decls, defaults, files, libs, programs, version):
    w = []
    w.append("//! Generated by tools/ffmpeg_gen.py from FFmpeg's configure and Makefiles. Do not edit.\n")
    w.append('const T = @import("../../../build/ffmpeg/resolve.zig");\n')
    w.append("pub const data: T.Data = .{")
    w.append(f"    .version = {zstr(version)},")
    w.append("    // configure's lists, in configure's order.")
    w.append("    .lists = .{")
    for name in LISTS:
        w.append(f"        .{name.lower()} = &.{{")
        for item in lists[name]:
            w.append(f"            {zstr(item)},")
        w.append("        },")
    w.append("    },")
    w.append("    // Every `<name>_deps`-style declaration reachable from check_deps' roots.")
    w.append("    .decls = &.{")
    for name in sorted(decls):
        d = decls[name]
        fields = [f".name = {zstr(name)}"] + [f".{ZIG_FIELD.get(k, k)} = {zlist(d[k])}" for k in DEP_KINDS if k in d]
        w.append("        .{ " + ", ".join(fields) + " },")
    w.append("    },")
    w.append("    // State after option parsing with the base options and no external libraries, before probes.")
    w.append("    .defaults = &.{")
    for name, val in defaults.items():
        w.append(f"        .{{ {zstr(name)}, .{val} }},")
    w.append("    },")
    w.append("    // print_enabled_components outputs: each entry is a component and the symbol it prints.")
    w.append("    .component_files = &.{")
    for path, struct, array, entries in files:
        w.append(f"        .{{ .path = {zstr(path)}, .struct_name = {zstr(struct)}, .array = {zstr(array)}, .entries = &.{{")
        for c, sym in entries:
            w.append(f"            .{{ {zstr(c)}, {zstr(sym)} }},")
        tail = zlist(FILTER_TAIL) if array == "filter_list" else "&.{}"
        w.append(f"        }}, .tail = {tail} }},")
    w.append("    },")
    w.append("    // Objects each library's Makefiles can build, with the names that must all be enabled.")
    w.append("    .libraries = &.{")
    for name, objects, headers, built, preprocessed, host_programs in libs:
        w.append(f"        .{{ .name = {zstr(name)}, .headers = {zlist(headers)}, .built_headers = {zlist(built)}, .objects = &.{{")
        for path, kind, scope, when, incs in objects:
            fields = [zstr(path), f".{kind}"]
            fields.append(zstr(scope))
            fields.append(zlist(when))
            fields.append(zlist(incs))
            w.append("            .{ " + ", ".join(fields) + " },")
        w.append("        }, .preprocessed = &.{")
        for target, source, scope in preprocessed:
            w.append(f"            .{{ {zstr(target)}, {zstr(source)}, {zstr(scope)} }},")
        w.append("        }, .host_programs = &.{")
        for prog, outputs in host_programs:
            outs = ", ".join(f".{{ {zstr(flag)}, {zstr(target)} }}" for flag, target in outputs)
            w.append(f"            .{{ .path = {zstr(prog)}, .outputs = &.{{ {outs} }} }},")
        w.append("        } },")
    w.append("    },")
    w.append("    // fftools' programs: C sources and the resources (.html, .css) embedded as C arrays.")
    w.append("    .programs = &.{")
    for name, sources, resources in programs:
        w.append(f"        .{{ .name = {zstr(name)}, .sources = {zlist(sources)}, .resources = {zlist(resources)} }},")
    w.append("    },")
    w.append("};")
    with open(out, "w") as f:
        f.write("\n".join(w) + "\n")


def main():
    src, out = sys.argv[1], sys.argv[2]
    lists, decls, defaults, files = configure_data(src)
    find_included(src)
    libs = makefile_data(src)
    programs = program_data(src)
    version = open(os.path.join(src, "VERSION")).read().strip()
    write(out, lists, decls, defaults, files, libs, programs, version)
    n = sum(len(l[1]) for l in libs)
    print(f"wrote {out}: {len(decls)} declarations, {len(defaults)} defaults, {n} objects")


if __name__ == "__main__":
    main()
