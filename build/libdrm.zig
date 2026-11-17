//! Core libdrm only; every GPU-specific helper library is off, as FFmpeg's VAAPI path needs none.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "libdrm",
    .version = "2.4.133",
    .ffmpeg = &.{"libdrm"},
    .ffmpeg_include_subdirs = &.{"libdrm"},
    .supports = Meta.support.linux,
};

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const src = c.upstream("libdrm");

    const mod = c.module(.{});
    mod.addIncludePath(c.b.path("gen/libdrm"));
    mod.addIncludePath(src.path(""));
    mod.addIncludePath(src.path("include/drm"));
    mod.addCSourceFiles(.{
        .root = src.path(""),
        .files = &.{ "xf86drm.c", "xf86drmHash.c", "xf86drmMode.c", "xf86drmRandom.c", "xf86drmSL.c" },
        .flags = &.{
            "-D_GNU_SOURCE=1",
            "-D_FILE_OFFSET_BITS=64",
            "-DHAVE_VISIBILITY=1",
            "-DHAVE_LIBDRM_ATOMIC_PRIMITIVES=1",
            "-DHAVE_LIB_ATOMIC_OPS=0",
            "-DHAVE_SYS_SYSCTL_H=0",
            "-DMAJOR_IN_SYSMACROS=1",
            "-DUDEV=0",
            "-fvisibility=hidden",
        },
    });

    const lib = c.staticLibrary("drm", mod);
    lib.installHeader(src.path("xf86drm.h"), "xf86drm.h");
    lib.installHeader(src.path("xf86drmMode.h"), "xf86drmMode.h");
    lib.installHeadersDirectory(src.path("include/drm"), "libdrm", .{});
    return c.single(lib);
}
