const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "zlib",
    .version = "1.3.2",
    .licenses = &.{"LICENSE"},
    .ffmpeg = &.{"zlib"},
    .ffmpeg_probes = &.{"zlib_gzip"},
};

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const src = c.upstream("zlib");
    const mod = c.module(.{});
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(c.b.allocator, &.{ "-DHAVE_SYS_TYPES_H", "-DHAVE_STDINT_H", "-DHAVE_STDDEF_H" }) catch @panic("OOM");
    if (!c.isWindows()) {
        flags.appendSlice(c.b.allocator, &.{ "-DZ_HAVE_UNISTD_H", "-D_LARGEFILE64_SOURCE=1", "-DHAVE_HIDDEN" }) catch @panic("OOM");
    }
    mod.addCSourceFiles(.{
        .root = src.path(""),
        .files = &.{
            "adler32.c", "compress.c", "crc32.c",   "deflate.c", "gzclose.c",  "gzlib.c", "gzread.c",
            "gzwrite.c", "infback.c",  "inffast.c", "inflate.c", "inftrees.c", "trees.c", "uncompr.c",
            "zutil.c",
        },
        .flags = flags.items,
    });
    const lib = c.staticLibrary("z", mod);
    lib.installHeader(src.path("zlib.h"), "zlib.h");
    lib.installHeader(src.path("zconf.h"), "zconf.h");
    return c.single(lib);
}
