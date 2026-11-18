const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "libogg",
    .version = "1.3.6",
    .spdx = "BSD-3-Clause",
    .licenses = &.{"COPYING"},
};

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const src = c.upstream("libogg");
    const mod = c.module(.{});

    const types = c.b.addConfigHeader(.{
        .style = .{ .autoconf_at = src.path("include/ogg/config_types.h.in") },
        .include_path = "ogg/config_types.h",
    }, .{
        .INCLUDE_INTTYPES_H = 1,
        .INCLUDE_STDINT_H = 1,
        .INCLUDE_SYS_TYPES_H = @as(i64, if (c.isMsvc()) 0 else 1),
        .SIZE16 = "int16_t",
        .USIZE16 = "uint16_t",
        .SIZE32 = "int32_t",
        .USIZE32 = "uint32_t",
        .SIZE64 = "int64_t",
        .USIZE64 = "uint64_t",
    });
    mod.addConfigHeader(types);
    mod.addIncludePath(src.path("include"));
    mod.addCSourceFiles(.{ .root = src.path("src"), .files = &.{ "bitwise.c", "framing.c" } });

    const lib = c.staticLibrary("ogg", mod);
    lib.installHeader(src.path("include/ogg/ogg.h"), "ogg/ogg.h");
    lib.installHeader(src.path("include/ogg/os_types.h"), "ogg/os_types.h");
    lib.installConfigHeader(types);
    return c.single(lib);
}
