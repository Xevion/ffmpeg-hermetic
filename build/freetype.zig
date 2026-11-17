const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "freetype",
    .version = "2.15.0",
    .licenses = &.{ "LICENSE.TXT", "docs/FTL.TXT", "docs/GPLv2.TXT" },
    .ffmpeg_include_subdirs = &.{"freetype2"},
};

/// FreeType with its bundled zlib and no optional PNG, bzip2, brotli or HarfBuzz support, so it
/// has no dependencies of its own.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const b = c.b;
    const src = c.upstream("freetype");
    const windows = c.isWindows();

    const mod = c.module(.{});
    mod.addIncludePath(src.path("include"));
    const flags: []const []const u8 = if (windows) &.{"-DFT2_BUILD_LIBRARY"} else &.{ "-DFT2_BUILD_LIBRARY", "-DHAVE_UNISTD_H", "-DHAVE_FCNTL_H" };
    mod.addCSourceFiles(.{ .root = src.path(""), .files = &sources, .flags = flags });
    mod.addCSourceFiles(.{
        .root = src.path(""),
        .files = if (windows) &.{ "builds/windows/ftsystem.c", "builds/windows/ftdebug.c" } else &.{ "builds/unix/ftsystem.c", "src/base/ftdebug.c" },
        .flags = flags,
    });

    const lib = c.staticLibrary("freetype", mod);
    lib.installHeader(src.path("include/ft2build.h"), "freetype2/ft2build.h");
    for (public_headers) |h| lib.installHeader(src.path(b.fmt("include/freetype/{s}", .{h})), b.fmt("freetype2/freetype/{s}", .{h}));
    for (config_headers) |h| lib.installHeader(src.path(b.fmt("include/freetype/config/{s}", .{h})), b.fmt("freetype2/freetype/config/{s}", .{h}));
    return c.single(lib);
}

const sources = [_][]const u8{
    "src/autofit/autofit.c",
    "src/base/ftbase.c",
    "src/base/ftbbox.c",
    "src/base/ftbdf.c",
    "src/base/ftbitmap.c",
    "src/base/ftcid.c",
    "src/base/ftfstype.c",
    "src/base/ftgasp.c",
    "src/base/ftglyph.c",
    "src/base/ftgxval.c",
    "src/base/ftinit.c",
    "src/base/ftmm.c",
    "src/base/ftotval.c",
    "src/base/ftpatent.c",
    "src/base/ftpfr.c",
    "src/base/ftstroke.c",
    "src/base/ftsynth.c",
    "src/base/fttype1.c",
    "src/base/ftwinfnt.c",
    "src/bdf/bdf.c",
    "src/bzip2/ftbzip2.c",
    "src/cache/ftcache.c",
    "src/cff/cff.c",
    "src/cid/type1cid.c",
    "src/gzip/ftgzip.c",
    "src/hvf/hvf.c",
    "src/lzw/ftlzw.c",
    "src/pcf/pcf.c",
    "src/pfr/pfr.c",
    "src/psaux/psaux.c",
    "src/pshinter/pshinter.c",
    "src/psnames/psnames.c",
    "src/raster/raster.c",
    "src/sdf/sdf.c",
    "src/sfnt/sfnt.c",
    "src/smooth/smooth.c",
    "src/svg/svg.c",
    "src/truetype/truetype.c",
    "src/type1/type1.c",
    "src/type42/type42.c",
    "src/winfonts/winfnt.c",
};

const public_headers = [_][]const u8{
    "freetype.h",   "ftadvanc.h",  "ftbbox.h",   "ftbdf.h",    "ftbitmap.h", "ftbzip2.h",  "ftcache.h",
    "ftchapters.h", "ftcid.h",     "ftcolor.h",  "ftdriver.h", "fterrdef.h", "fterrors.h", "ftfntfmt.h",
    "ftgasp.h",     "ftglyph.h",   "ftgxval.h",  "ftgzip.h",   "ftimage.h",  "ftincrem.h", "ftlcdfil.h",
    "ftlist.h",     "ftlogging.h", "ftlzw.h",    "ftmac.h",    "ftmm.h",     "ftmodapi.h", "ftmoderr.h",
    "ftotval.h",    "ftoutln.h",   "ftparams.h", "ftpfr.h",    "ftrender.h", "ftsizes.h",  "ftsnames.h",
    "ftstroke.h",   "ftsynth.h",   "ftsystem.h", "fttrigon.h", "fttypes.h",  "ftwinfnt.h", "otsvg.h",
    "t1tables.h",   "ttnameid.h",  "tttables.h", "tttags.h",
};

const config_headers = [_][]const u8{
    "ftconfig.h", "ftheader.h", "ftmodule.h", "ftoption.h", "ftstdlib.h", "integer-types.h", "mac-support.h", "public-macros.h",
};
