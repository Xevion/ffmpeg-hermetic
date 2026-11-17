const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// Speex, floating-point, with the Vorbis FFT and, on x86, the baseline SSE kernels.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const b = c.b;
    const src = c.upstream("speex");
    const x86 = c.arch() == .x86_64;
    const posix: ?i64 = if (c.isWindows()) null else 1;

    const config = b.addConfigHeader(.{ .style = .{ .autoconf_undef = src.path("config.h.in") } }, .{
        .AC_APPLE_UNIVERSAL_BUILD = null,
        .ARM4_ASM = null,
        .ARM5E_ASM = null,
        .BFIN_ASM = null,
        .DISABLE_FLOAT_API = null,
        .DISABLE_VBR = null,
        .ENABLE_VALGRIND = null,
        .EXPORT = null,
        .FIXED_DEBUG = null,
        .FIXED_POINT = null,
        .FLOATING_POINT = 1,
        .HAVE_ALLOCA_H = posix,
        .HAVE_DLFCN_H = null,
        .HAVE_GETOPT_H = null,
        .HAVE_GETOPT_LONG = null,
        .HAVE_INTTYPES_H = 1,
        .HAVE_STDINT_H = 1,
        .HAVE_STDIO_H = 1,
        .HAVE_STDLIB_H = 1,
        .HAVE_STRINGS_H = posix,
        .HAVE_STRING_H = 1,
        .HAVE_SYS_AUDIOIO_H = null,
        .HAVE_SYS_SOUNDCARD_H = null,
        .HAVE_SYS_STAT_H = 1,
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_UNISTD_H = posix,
        .LT_OBJDIR = ".libs/",
        .PACKAGE_BUGREPORT = "speex-dev@xiph.org",
        .PACKAGE_NAME = "speex",
        .PACKAGE_STRING = "speex 1.2.1",
        .PACKAGE_TARNAME = "speex",
        .PACKAGE_URL = "",
        .PACKAGE_VERSION = "1.2.1",
        .SIZEOF_INT = 4,
        .SIZEOF_INT16_T = 2,
        .SIZEOF_INT32_T = 4,
        .SIZEOF_LONG = @as(i64, c.target.result.cTypeByteSize(.long).?),
        .SIZEOF_SHORT = 2,
        .SIZEOF_UINT16_T = 2,
        .SIZEOF_UINT32_T = 4,
        .SIZEOF_U_INT16_T = if (c.isWindows()) @as(?i64, 0) else 2,
        .SIZEOF_U_INT32_T = if (c.isWindows()) @as(?i64, 0) else 4,
        .SPEEX_EXTRA_VERSION = "",
        .SPEEX_MAJOR_VERSION = 1,
        .SPEEX_MICRO_VERSION = 1,
        .SPEEX_MINOR_VERSION = 2,
        .SPEEX_VERSION = "1.2.1",
        .STDC_HEADERS = 1,
        .TI_C55X = null,
        .USE_ALLOCA = null,
        .USE_GPL_FFTW3 = null,
        .USE_INTEL_MKL = null,
        .USE_KISS_FFT = null,
        .USE_SMALLFT = 1,
        .USE_SPEEXDSP = null,
        .VAR_ARRAYS = 1,
        .VORBIS_PSYCHO = null,
        .WORDS_BIGENDIAN = null,
        ._USE_SSE = if (x86) @as(?i64, 1) else null,
        .@"const" = null,
        .@"inline" = null,
        .restrict = null,
    });
    const types = b.addConfigHeader(.{
        .style = .{ .cmake = src.path("include/speex/speex_config_types.h.in") },
        .include_path = "speex/speex_config_types.h",
    }, .{
        .INCLUDE_STDINT = "#include <stdint.h>",
        .SIZE16 = "int16_t",
        .USIZE16 = "uint16_t",
        .SIZE32 = "int32_t",
        .USIZE32 = "uint32_t",
    });

    const mod = c.module(.{});
    mod.addConfigHeader(config);
    mod.addConfigHeader(types);
    mod.addIncludePath(types.getOutputDir().path(b, "speex"));
    mod.addIncludePath(src.path("include"));
    mod.addIncludePath(src.path("libspeex"));
    mod.addCSourceFiles(.{ .root = src.path("libspeex"), .files = &sources, .flags = &.{ "-DHAVE_CONFIG_H", "-fvisibility=hidden", "-DEXPORT=__attribute__((visibility(\"default\")))" } });

    const lib = c.staticLibrary("speex", mod);
    for (headers) |h| lib.installHeader(src.path(b.fmt("include/speex/{s}", .{h})), b.fmt("speex/{s}", .{h}));
    lib.installConfigHeader(types);
    return c.single(lib);
}

const headers = [_][]const u8{ "speex.h", "speex_bits.h", "speex_callbacks.h", "speex_header.h", "speex_stereo.h", "speex_types.h" };

const sources = [_][]const u8{
    "cb_search.c",       "exc_10_32_table.c", "exc_8_128_table.c", "filters.c",        "gain_table.c",
    "hexc_table.c",      "high_lsp_tables.c", "lsp.c",             "ltp.c",            "speex.c",
    "stereo.c",          "vbr.c",             "vq.c",              "bits.c",           "exc_10_16_table.c",
    "exc_20_32_table.c", "exc_5_256_table.c", "exc_5_64_table.c",  "gain_table_lbr.c", "hexc_10_32_table.c",
    "lpc.c",             "lsp_tables_nb.c",   "modes.c",           "modes_wb.c",       "nb_celp.c",
    "quant_lsp.c",       "sb_celp.c",         "speex_callbacks.c", "speex_header.c",   "window.c",
};
