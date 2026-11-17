const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "vidstab",
    .version = "1.1.2",
    .licenses = &.{"LICENSE"},
    .ffmpeg = &.{"libvidstab"},
    .license = .gpl,
    .ffmpeg_windows_defines = &.{"VIDSTAB_EXPORTS"},
    .system_libs = .{ .linux = &.{"m"} },
};

/// vid.stab, the video stabilization library, with its SSE2 motion search on x86 and no OpenMP.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const b = c.b;
    const src = c.lazyUpstream("vidstab") orelse return null;

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{ "-std=gnu99", "-Wno-pointer-sign" }) catch @panic("OOM");
    // vidstab_api.h makes every symbol dllimport on msvc unless this is set.
    if (c.isMsvc()) flags.append(b.allocator, "-DVIDSTAB_EXPORTS") catch @panic("OOM");
    if (c.arch() == .x86_64) flags.appendSlice(b.allocator, &.{ "-DUSE_SSE2", "-ffast-math" }) catch @panic("OOM");

    const mod = c.module(.{});
    mod.addIncludePath(src.path("src"));
    mod.addCSourceFiles(.{ .root = src.path(""), .files = &sources, .flags = flags.items });

    const lib = c.staticLibrary("vidstab", mod);
    for (headers) |h| lib.installHeader(src.path(b.fmt("src/{s}", .{h})), b.fmt("vid.stab/{s}", .{h}));
    return c.single(lib);
}

const sources = [_][]const u8{
    "src/frameinfo.c",    "src/transformtype.c",    "src/libvidstab.c", "src/transform.c",             "src/transformfixedpoint.c",
    "src/motiondetect.c", "src/motiondetect_opt.c", "src/serialize.c",  "src/localmotion2transform.c", "src/boxblur.c",
    "src/vsvector.c",
};

const headers = [_][]const u8{
    "boxblur.h",                  "compat.h",                "frameinfo.h",           "libvidstab.h",     "localmotion2transform.h",
    "motiondetect.h",             "motiondetect_internal.h", "motiondetect_opt.h",    "serialize.h",      "sse2neon.h",
    "transform.h",                "transform_internal.h",    "transformfixedpoint.h", "transformfloat.h", "transformtype.h",
    "transformtype_operations.h", "vidstab_api.h",           "vidstabdefines.h",      "vsvector.h",
};
