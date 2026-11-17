const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "libass",
    .version = "0.17.5",
    .licenses = &.{"COPYING"},
    .needs = &.{ "freetype", "fribidi", "harfbuzz" },
    .ffmpeg = &.{"libass"},
    .system_libs = .{ .linux = &.{"m"} },
};

/// libass with no system font provider (no fontconfig, CoreText or DirectWrite) and no
/// libunibreak. The x86_64 assembly picks its instruction set at runtime.
pub fn build(c: Ctx, nasm: Nasm) ?Ctx.Output {
    const b = c.b;
    const src = c.upstream("libass");
    const x86 = c.arch() == .x86_64;
    const t = c.target.result;

    const config = b.addConfigHeader(.{ .style = .{ .autoconf_undef = src.path("config.h.in") } }, .{
        .ARCH_AARCH64 = null,
        .ARCH_X86 = if (x86) @as(?i64, 1) else null,
        .ARCH_X86_64 = if (x86) @as(?i64, 1) else null,
        .CONFIG_ASM = if (x86) @as(?i64, 1) else null,
        .CONFIG_CORETEXT = null,
        .CONFIG_DIRECTWRITE = null,
        .CONFIG_FONTCONFIG = null,
        .CONFIG_ICONV = if (t.os.tag == .linux) @as(?i64, 1) else null,
        .CONFIG_LARGE_TILES = 0,
        .CONFIG_LIBPNG = null,
        .CONFIG_SOURCEVERSION = "zig build",
        .CONFIG_UNIBREAK = null,
        .HAVE_DLFCN_H = null,
        .HAVE_ICONV_H = if (t.os.tag == .linux) @as(?i64, 1) else null,
        .HAVE_INTTYPES_H = 1,
        .HAVE_STDINT_H = 1,
        .HAVE_STDIO_H = 1,
        .HAVE_STDLIB_H = 1,
        .HAVE_STRDUP = 1,
        .HAVE_STRINGS_H = if (c.isWindows()) null else @as(?i64, 1),
        .HAVE_STRING_H = 1,
        .HAVE_STRNDUP = if (c.isWindows()) null else @as(?i64, 1),
        .HAVE_SYS_STAT_H = 1,
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_UNISTD_H = if (c.isWindows()) null else @as(?i64, 1),
        .LT_OBJDIR = ".libs/",
        .PACKAGE = "libass",
        .PACKAGE_BUGREPORT = "",
        .PACKAGE_NAME = "libass",
        .PACKAGE_STRING = "libass " ++ meta.version,
        .PACKAGE_TARNAME = "libass",
        .PACKAGE_URL = "",
        .PACKAGE_VERSION = meta.version,
        .STDC_HEADERS = 1,
        .VERSION = meta.version,
    });

    const freetype = c.dep("freetype");
    const mod = c.module(.{});
    mod.addConfigHeader(config);
    mod.addIncludePath(src.path(""));
    mod.addIncludePath(src.path("libass"));
    mod.addIncludePath(freetype.include);
    mod.addIncludePath(freetype.include.path(b, "freetype2"));
    mod.addIncludePath(c.dep("fribidi").include.path(b, "fribidi"));
    mod.addIncludePath(c.dep("harfbuzz").include.path(b, "harfbuzz"));
    mod.addCSourceFiles(.{
        .root = src.path("libass"),
        .files = &sources,
        .flags = &.{ "-D_GNU_SOURCE", "-D_XPLATFORM_SOURCE", "-fno-math-errno", "-std=gnu99" },
    });
    if (x86) {
        var flags: std.ArrayList([]const u8) = .empty;
        flags.appendSlice(b.allocator, &.{ "-Dprivate_prefix=ass", "-DPIC=1", "-DARCH_X86_64=1" }) catch @panic("OOM");
        if (t.os.tag == .macos) flags.appendSlice(b.allocator, &.{ "-DPREFIX", "-DSTACK_ALIGNMENT=16" }) catch @panic("OOM");
        if (t.os.tag == .linux) flags.append(b.allocator, "-DSTACK_ALIGNMENT=16") catch @panic("OOM");
        nasm.addFiles(c, mod, .{
            .root = src.path("libass"),
            .files = &.{ "x86/rasterizer.asm", "x86/blend_bitmaps.asm", "x86/be_blur.asm", "x86/blur.asm", "x86/cpuid.asm" },
            .include_dirs = &.{src.path("libass")},
            .flags = flags.items,
        });
    }

    const lib = c.staticLibrary("ass", mod);
    lib.installHeader(src.path("libass/ass.h"), "ass/ass.h");
    lib.installHeader(src.path("libass/ass_types.h"), "ass/ass_types.h");
    return c.single(lib);
}

const sources = [_][]const u8{
    "c/c_be_blur.c", "c/c_blend_bitmaps.c",  "c/c_blur.c",    "c/c_rasterizer.c",
    "ass.c",         "ass_arabic_charmap.c", "ass_bitmap.c",  "ass_bitmap_engine.c",
    "ass_blur.c",    "ass_cache.c",          "ass_drawing.c", "ass_filesystem.c",
    "ass_font.c",    "ass_fontselect.c",     "ass_library.c", "ass_outline.c",
    "ass_parse.c",   "ass_rasterizer.c",     "ass_render.c",  "ass_render_api.c",
    "ass_shaper.c",  "ass_string.c",         "ass_strtod.c",  "ass_utils.c",
};
