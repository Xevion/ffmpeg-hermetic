const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "openjpeg",
    .version = "2.5.4",
    .licenses = &.{"LICENSE"},
    .ffmpeg_include_subdirs = &.{"openjpeg-2.5"},
    .system_libs = .{ .linux = &.{"m"} },
};

/// OpenJPEG's libopenjp2. Its vector code in dwt, t1 and mct is chosen at compile time
/// (`__SSE2__`), so there is nothing to dispatch at runtime.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const ver = Meta.versionParts(meta.version);
    const b = c.b;
    const src = c.upstream("openjpeg");
    const lib_src = src.path("src/lib/openjp2");
    const windows = c.isWindows();
    const apple = c.os().isDarwin();

    const public = b.addConfigHeader(.{
        .style = .{ .cmake = lib_src.path(b, "opj_config.h.cmake.in") },
        .include_path = "opj_config.h",
    }, .{
        .OPENJPEG_VERSION_MAJOR = ver[0],
        .OPENJPEG_VERSION_MINOR = ver[1],
        .OPENJPEG_VERSION_BUILD = ver[2],
    });
    const private = b.addConfigHeader(.{
        .style = .{ .cmake = lib_src.path(b, "opj_config_private.h.cmake.in") },
        .include_path = "opj_config_private.h",
    }, .{
        .PACKAGE_VERSION = meta.version,
        .HAVE_MEMORY_H = null,
        .HAVE_STDLIB_H = null,
        .HAVE_STRINGS_H = null,
        .HAVE_STRING_H = null,
        .HAVE_SYS_STAT_H = null,
        .HAVE_SYS_TYPES_H = null,
        .HAVE_UNISTD_H = null,
        .HAVE_INTTYPES_H = null,
        .HAVE_STDINT_H = null,
        ._LARGEFILE_SOURCE = if (windows) null else @as(?i64, 1),
        ._LARGE_FILES = null,
        ._FILE_OFFSET_BITS = if (windows) null else @as(?i64, 64),
        .OPJ_HAVE_FSEEKO = if (windows) null else @as(?i64, 1),
        .OPJ_HAVE_MALLOC_H = if (apple) null else @as(?i64, 1),
        .OPJ_HAVE_ALIGNED_ALLOC = null,
        .OPJ_HAVE__ALIGNED_MALLOC = if (windows) @as(?i64, 1) else null,
        .OPJ_HAVE_MEMALIGN = if (c.os() == .linux) @as(?i64, 1) else null,
        .OPJ_HAVE_POSIX_MEMALIGN = if (windows) null else @as(?i64, 1),
        .OPJ_BIG_ENDIAN = if (c.target.result.cpu.arch.endian() == .big) @as(?i64, 1) else null,
    });

    const mod = c.module(.{});
    mod.addConfigHeader(public);
    mod.addConfigHeader(private);
    mod.addIncludePath(lib_src);
    mod.addCSourceFiles(.{
        .root = lib_src,
        .files = &sources,
        .flags = &.{ "-DOPJ_STATIC", "-fvisibility=hidden" },
    });

    const lib = c.staticLibrary("openjp2", mod);
    lib.installHeader(lib_src.path(b, "openjpeg.h"), "openjpeg-2.5/openjpeg.h");
    lib.installHeader(public.getOutputFile(), "openjpeg-2.5/opj_config.h");
    return c.single(lib);
}

const sources = [_][]const u8{
    "thread.c",   "bio.c",           "cio.c",        "dwt.c",          "event.c", "ht_dec.c",
    "image.c",    "invert.c",        "j2k.c",        "jp2.c",          "mct.c",   "mqc.c",
    "openjpeg.c", "opj_clock.c",     "pi.c",         "t1.c",           "t2.c",    "tcd.c",
    "tgt.c",      "function_list.c", "opj_malloc.c", "sparse_array.c",
};
