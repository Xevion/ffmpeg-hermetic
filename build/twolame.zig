const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// TwoLAME, the MPEG audio layer 2 encoder.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const b = c.b;
    const src = c.upstream("twolame");
    const posix: ?i64 = if (c.isWindows()) null else 1;

    const config = b.addConfigHeader(.{ .style = .{ .autoconf_undef = src.path("libtwolame/config.h.in") } }, .{
        .AC_APPLE_UNIVERSAL_BUILD = null,
        .HAVE_ASSERT_H = 1,
        .HAVE_DLFCN_H = null,
        .HAVE_INTTYPES_H = 1,
        .HAVE_LIBM = 1,
        .HAVE_LIBMX = null,
        .HAVE_MALLOC_H = if (c.os().isDarwin()) null else @as(?i64, 1),
        .HAVE_MEMORY_H = 1,
        .HAVE_STDINT_H = 1,
        .HAVE_STDLIB_H = 1,
        .HAVE_STRINGS_H = posix,
        .HAVE_STRING_H = 1,
        .HAVE_SYS_STAT_H = 1,
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_UNISTD_H = posix,
        .LT_OBJDIR = ".libs/",
        .PACKAGE = "twolame",
        .PACKAGE_BUGREPORT = "twolame-discuss@lists.sourceforge.net",
        .PACKAGE_NAME = "TwoLAME",
        .PACKAGE_STRING = "TwoLAME 0.4.0",
        .PACKAGE_TARNAME = "twolame",
        .PACKAGE_URL = "http://www.twolame.org/",
        .PACKAGE_VERSION = "0.4.0",
        .SIZEOF_FLOAT = 4,
        .SIZEOF_SHORT = 2,
        .STDC_HEADERS = 1,
        .VERSION = "0.4.0",
        .WORDS_BIGENDIAN = null,
        .@"const" = null,
        .@"inline" = null,
    });

    const mod = c.module(.{});
    mod.addConfigHeader(config);
    mod.addCSourceFiles(.{
        .root = src.path("libtwolame"),
        .files = &sources,
        .flags = &.{ "-DLIBTWOLAME_BUILD", "-DLIBTWOLAME_STATIC", "-std=gnu99" },
    });

    const lib = c.staticLibrary("twolame", mod);
    lib.installHeader(src.path("libtwolame/twolame.h"), "twolame.h");
    return c.single(lib);
}

const sources = [_][]const u8{
    "ath.c",      "availbits.c", "bitbuffer.c", "crc.c",      "dab.c",      "encode.c",   "energy.c",
    "fft.c",      "get_set.c",   "mem.c",       "psycho_0.c", "psycho_1.c", "psycho_2.c", "psycho_3.c",
    "psycho_4.c", "psycho_n1.c", "subband.c",   "twolame.c",  "util.c",
};
