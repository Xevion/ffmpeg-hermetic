const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// HarfBuzz's core shaper with its FreeType integration, from the single-file amalgamation.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const b = c.b;
    const src = c.upstream("harfbuzz");
    const freetype = c.dep("freetype");
    const t = c.target.result;

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{
        "-std=c++14",                            "-fno-exceptions",                       "-fno-rtti",
        "-fno-threadsafe-statics",               "-DHAVE_STDBOOL_H",                      "-DHAVE_FREETYPE=1",
        "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1", "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1", "-DHAVE_FT_DONE_MM_VAR=1",
        "-DHAVE_FT_GET_TRANSFORM=1",
    }) catch @panic("OOM");
    if (!c.isWindows()) flags.appendSlice(b.allocator, &.{
        "-DHAVE_PTHREAD=1", "-DHAVE_UNISTD_H", "-DHAVE_SYS_MMAN_H",  "-DHAVE_ATEXIT",
        "-DHAVE_MPROTECT",  "-DHAVE_SYSCONF",  "-DHAVE_GETPAGESIZE", "-DHAVE_MMAP",
        "-DHAVE_ISATTY",
    }) catch @panic("OOM");
    if (t.os.tag == .linux) flags.appendSlice(b.allocator, &.{ "-DHAVE_SINCOS", "-DHAVE_SINCOSF", "-DHAVE_NEWLOCALE", "-DHAVE_USELOCALE" }) catch @panic("OOM");
    if (t.os.tag.isDarwin()) flags.appendSlice(b.allocator, &.{ "-DHAVE_XLOCALE_H", "-DHAVE_NEWLOCALE", "-DHAVE_USELOCALE", "-DHAVE_LOCALECONV_L" }) catch @panic("OOM");

    const mod = c.module(.{ .cpp = true });
    mod.addIncludePath(src.path("src"));
    mod.addIncludePath(freetype.include);
    mod.addIncludePath(freetype.include.path(b, "freetype2"));
    if (c.isMsvc()) {
        // The UCRT's NAN is inf * 0, which clang rejects in a constexpr initializer.
        const wrapper = b.addWriteFiles().add("harfbuzz_msvc.cc",
            \\#include <math.h>
            \\#undef NAN
            \\#define NAN __builtin_nanf("")
            \\#include "harfbuzz.cc"
            \\
        );
        mod.addCSourceFile(.{ .file = wrapper, .flags = flags.items });
    } else {
        mod.addCSourceFiles(.{ .root = src.path("src"), .files = &.{"harfbuzz.cc"}, .flags = flags.items });
    }

    const lib = c.staticLibrary("harfbuzz", mod);
    for (headers) |h| lib.installHeader(src.path(b.fmt("src/{s}", .{h})), b.fmt("harfbuzz/{s}", .{h}));
    return c.single(lib);
}

const headers = [_][]const u8{
    "hb-aat-layout.h", "hb-aat.h",        "hb-blob.h",     "hb-buffer.h",        "hb-common.h",
    "hb-cplusplus.hh", "hb-deprecated.h", "hb-draw.h",     "hb-paint.h",         "hb-face.h",
    "hb-font.h",       "hb-map.h",        "hb-ot-color.h", "hb-ot-deprecated.h", "hb-ot-fetch.h",
    "hb-ot-font.h",    "hb-ot-layout.h",  "hb-ot-math.h",  "hb-ot-meta.h",       "hb-ot-metrics.h",
    "hb-ot-name.h",    "hb-ot-shape.h",   "hb-ot-var.h",   "hb-ot.h",            "hb-script-list.h",
    "hb-set.h",        "hb-shape-plan.h", "hb-shape.h",    "hb-style.h",         "hb-unicode.h",
    "hb.h",            "hb-version.h",    "hb-ft.h",
};
