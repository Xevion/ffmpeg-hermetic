//! LAME's encoder only: the mpglib decoder and the frontend stay out, as in `--disable-decoder`.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "lame",
    .version = "4.0",
    .licenses = &.{ "COPYING", "LICENSE" },
    .ffmpeg = &.{"libmp3lame"},
    .system_libs = .{ .linux = &.{"m"} },
};

const version = meta.version;

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const b = c.b;
    const t = c.target.result;
    const src = c.upstream("lame");
    const mod = c.module(.{});
    const posix = !c.isWindows();
    const x86 = t.cpu.arch.isX86();

    const config = b.addConfigHeader(.{ .style = .{ .autoconf_undef = src.path("config.h.in") } }, .{
        .ABORTFP = null,
        .AC_APPLE_UNIVERSAL_BUILD = null,
        .C_ALLOCA = null,
        .DEBUG = null,
        .DECODE_ON_THE_FLY = null,
        .FLOAT = null,
        .HAVE_ALLOCA = 1,
        .HAVE_ALLOCA_H = have(posix),
        .HAVE_DLFCN_H = have(posix),
        .HAVE_EFENCE = null,
        .HAVE_ERRNO_H = 1,
        .HAVE_FCNTL_H = 1,
        .HAVE_GETTIMEOFDAY = have(posix),
        .HAVE_ICONV = null,
        .HAVE_IEEE754_FLOAT32_T = null,
        .HAVE_IEEE754_FLOAT64_T = null,
        .HAVE_IEEE854_FLOAT80 = have(t.cTypeBitSize(.longdouble).? == 80),
        .HAVE_IEEE854_FLOAT80_T = null,
        .HAVE_INT16_T = 1,
        .HAVE_INT32_T = 1,
        .A_INT32_T = .int32_t,
        .HAVE_INT64_T = 1,
        .A_INT64_T = .int64_t,
        .HAVE_INT8_T = 1,
        .HAVE_INTTYPES_H = 1,
        .HAVE_LIMITS_H = 1,
        .HAVE_LANGINFO_H = have(posix),
        .HAVE_LINUX_SOUNDCARD_H = null,
        .HAVE_LONG_DOUBLE = 1,
        .HAVE_LONG_DOUBLE_WIDER = have(t.cTypeBitSize(.longdouble).? > t.cTypeBitSize(.double).?),
        .HAVE_MINIX_CONFIG_H = null,
        .HAVE_MPG123 = null,
        .HAVE_NASM = null,
        .HAVE_NCURSES_TERMCAP_H = null,
        .HAVE_NL_LANGINFO = have(posix),
        .HAVE_SOCKET = have(posix),
        .HAVE_STDINT_H = 1,
        .HAVE_STDIO_H = 1,
        .HAVE_STDLIB_H = 1,
        .HAVE_STRINGS_H = have(posix),
        .HAVE_STRING_H = 1,
        .HAVE_STRTOL = 1,
        .HAVE_SYS_SOUNDCARD_H = null,
        .HAVE_SYS_STAT_H = 1,
        .HAVE_SYS_TIME_H = have(posix),
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_TERMCAP = null,
        .HAVE_TERMCAP_H = null,
        .HAVE_UINT16_T = 1,
        .HAVE_UINT32_T = 1,
        .A_UINT32_T = .uint32_t,
        .HAVE_UINT64_T = 1,
        .A_UINT64_T = .uint64_t,
        .HAVE_UINT8_T = 1,
        .HAVE_UNISTD_H = have(posix),
        .HAVE_WCHAR_H = 1,
        .HAVE_XMMINTRIN_H = have(x86),
        .ICONV_CONST = {},
        .IPV6 = null,
        .LAME_LIBRARY_BUILD = 1,
        .LIBSNDFILE = null,
        .LT_OBJDIR = ".libs/",
        .MMX_choose_table = null,
        .NOANALYSIS = null,
        .PACKAGE = "lame",
        .PACKAGE_BUGREPORT = "lame-dev@lists.sf.net",
        .PACKAGE_NAME = "lame",
        .PACKAGE_STRING = "lame " ++ version,
        .PACKAGE_TARNAME = "lame",
        .PACKAGE_URL = "",
        .PACKAGE_VERSION = version,
        .SIZEOF_DOUBLE = t.cTypeByteSize(.double),
        .SIZEOF_FLOAT = t.cTypeByteSize(.float),
        .SIZEOF_INT = t.cTypeByteSize(.int),
        .SIZEOF_LONG = t.cTypeByteSize(.long),
        .SIZEOF_LONG_DOUBLE = t.cTypeByteSize(.longdouble),
        .SIZEOF_LONG_LONG = t.cTypeByteSize(.longlong),
        .SIZEOF_SHORT = t.cTypeByteSize(.short),
        .SIZEOF_UNSIGNED_INT = t.cTypeByteSize(.uint),
        .SIZEOF_UNSIGNED_LONG = t.cTypeByteSize(.ulong),
        .SIZEOF_UNSIGNED_LONG_LONG = t.cTypeByteSize(.ulonglong),
        .SIZEOF_UNSIGNED_SHORT = t.cTypeByteSize(.ushort),
        .STACK_DIRECTION = null,
        .STDC_HEADERS = 1,
        .TAKEHIRO_IEEE754_HACK = 0,
        .TIME_WITH_SYS_TIME = have(posix),
        .USE_FAST_LOG = have(x86 or t.cpu.arch.isPowerPC()),
        ._ALL_SOURCE = 1,
        ._COSMO_SOURCE = 1,
        ._DARWIN_C_SOURCE = 1,
        ._GNU_SOURCE = 1,
        ._HPUX_ALT_XOPEN_SOCKET_API = 1,
        ._NETBSD_SOURCE = 1,
        ._OPENBSD_SOURCE = 1,
        ._POSIX_PTHREAD_SEMANTICS = 1,
        .__STDC_WANT_IEC_60559_ATTRIBS_EXT__ = 1,
        .__STDC_WANT_IEC_60559_BFP_EXT__ = 1,
        .__STDC_WANT_IEC_60559_DFP_EXT__ = 1,
        .__STDC_WANT_IEC_60559_EXT__ = 1,
        .__STDC_WANT_IEC_60559_FUNCS_EXT__ = 1,
        .__STDC_WANT_IEC_60559_TYPES_EXT__ = 1,
        .__STDC_WANT_LIB_EXT2__ = 1,
        .__STDC_WANT_MATH_SPEC_FUNCS__ = 1,
        ._TANDEM_SOURCE = 1,
        .__EXTENSIONS__ = 1,
        .WORDS_BIGENDIAN = have(t.cpu.arch.endian() == .big),
        .VERSION = version,
        .WITH_DMALLOC = null,
        ._FILE_OFFSET_BITS = null,
        ._LARGE_FILES = null,
        ._TIME_BITS = null,
        ._XOPEN_SOURCE = null,
        .__MINGW_USE_VC2005_COMPAT = null,
        ._MINIX = null,
        ._POSIX_1_SOURCE = null,
        ._POSIX_SOURCE = null,
        .__DECALPHA__ = null,
        .__NO_MATH_INLINES = null,
        .@"const" = null,
        .@"inline" = null,
        .size_t = null,
    });
    mod.addConfigHeader(config);
    for ([_][]const u8{ "", "include", "libmp3lame" }) |dir| mod.addIncludePath(src.path(dir));
    mod.addCSourceFiles(.{
        .root = src.path("libmp3lame"),
        .files = &.{
            "VbrTag.c",   "bitstream.c",    "encoder.c",     "fft.c",     "gain_analysis.c",
            "id3tag.c",   "lame.c",         "newmdct.c",     "presets.c", "psymodel.c",
            "quantize.c", "quantize_pvt.c", "reservoir.c",   "set_get.c", "tables.c",
            "takehiro.c", "util.c",         "vbrquantize.c", "version.c", "mpglib_interface.c",
        },
        .flags = &.{"-DHAVE_CONFIG_H"},
    });
    if (x86) {
        mod.addCSourceFile(.{ .file = src.path("libmp3lame/vector/xmm_quantize_sub.c"), .flags = &.{"-DHAVE_CONFIG_H"} });
    }

    const lib = c.staticLibrary("mp3lame", mod);
    lib.installHeadersDirectory(src.path("include"), "lame", .{ .include_extensions = &.{"lame.h"} });
    return c.single(lib);
}

fn have(condition: bool) ?c_int {
    return if (condition) 1 else null;
}
