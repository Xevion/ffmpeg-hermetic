const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// liblzma. CRC acceleration uses function-level `target` attributes with a cpuid check, so no
/// extra module features are needed.
pub fn build(c: Ctx, _: Nasm) *std.Build.Step.Compile {
    const b = c.b;
    const src = c.upstream("xz");
    const t = c.target.result;
    const x86 = c.arch() == .x86_64;

    var flags: std.ArrayList([]const u8) = .empty;
    const add = struct {
        fn f(list: *std.ArrayList([]const u8), a: std.mem.Allocator, items: []const []const u8) void {
            list.appendSlice(a, items) catch @panic("OOM");
        }
    }.f;
    add(&flags, b.allocator, &.{
        "-DHAVE_CHECK_CRC32",                "-DHAVE_CHECK_CRC64",       "-DHAVE_CHECK_SHA256",
        "-DHAVE_DECODERS",                   "-DHAVE_ENCODERS",          "-DHAVE_LZIP_DECODER",
        "-DHAVE_DECODER_LZMA1",              "-DHAVE_DECODER_LZMA2",     "-DHAVE_DECODER_DELTA",
        "-DHAVE_DECODER_X86",                "-DHAVE_DECODER_ARM",       "-DHAVE_DECODER_ARMTHUMB",
        "-DHAVE_DECODER_ARM64",              "-DHAVE_DECODER_POWERPC",   "-DHAVE_DECODER_IA64",
        "-DHAVE_DECODER_SPARC",              "-DHAVE_DECODER_RISCV",     "-DHAVE_ENCODER_LZMA1",
        "-DHAVE_ENCODER_LZMA2",              "-DHAVE_ENCODER_DELTA",     "-DHAVE_ENCODER_X86",
        "-DHAVE_ENCODER_ARM",                "-DHAVE_ENCODER_ARMTHUMB",  "-DHAVE_ENCODER_ARM64",
        "-DHAVE_ENCODER_POWERPC",            "-DHAVE_ENCODER_IA64",      "-DHAVE_ENCODER_SPARC",
        "-DHAVE_ENCODER_RISCV",              "-DHAVE_MF_BT2",            "-DHAVE_MF_BT3",
        "-DHAVE_MF_BT4",                     "-DHAVE_MF_HC3",            "-DHAVE_MF_HC4",
        "-DHAVE_STDBOOL_H",                  "-DHAVE_STDINT_H",          "-DHAVE_INTTYPES_H",
        "-DHAVE__BOOL",                      "-DHAVE___BUILTIN_BSWAPXX", "-DHAVE___BUILTIN_ASSUME_ALIGNED",
        "-DHAVE_FUNC_ATTRIBUTE_CONSTRUCTOR", "-DHAVE_VISIBILITY=0",      "-DTUKLIB_SYMBOL_PREFIX=lzma_",
        "-DNDEBUG",
    });
    if (x86) add(&flags, b.allocator, &.{
        "-DHAVE_CPUID_H",           "-DHAVE_IMMINTRIN_H",             "-DHAVE_USABLE_CLMUL",
        "-DHAVE__MM_MOVEMASK_EPI8", "-DTUKLIB_FAST_UNALIGNED_ACCESS",
    });
    if (c.arch() == .aarch64) add(&flags, b.allocator, &.{"-DTUKLIB_FAST_UNALIGNED_ACCESS"});
    if (c.isWindows()) {
        add(&flags, b.allocator, &.{ "-DMYTHREAD_VISTA", "-DTUKLIB_CPUCORES_WINDOWS", "-DTUKLIB_PHYSMEM_WINDOWS", "-DWIN32_LEAN_AND_MEAN" });
    } else {
        add(&flags, b.allocator, &.{
            "-DMYTHREAD_POSIX",         "-DHAVE_CLOCK_GETTIME", "-DHAVE_CLOCK_MONOTONIC",
            "-DTUKLIB_PHYSMEM_SYSCONF", "-D_GNU_SOURCE",
        });
        if (t.os.tag == .linux) add(&flags, b.allocator, &.{ "-DHAVE_PTHREAD_CONDATTR_SETCLOCK", "-DTUKLIB_CPUCORES_SCHED_GETAFFINITY" });
        if (t.os.tag.isDarwin()) add(&flags, b.allocator, &.{ "-DTUKLIB_CPUCORES_SYSCTL", "-D_DARWIN_C_SOURCE" });
    }

    const mod = c.module(.{});
    for ([_][]const u8{ "api", "common", "check", "lz", "rangecoder", "lzma", "delta", "simple" }) |dir| {
        mod.addIncludePath(src.path(b.fmt("src/liblzma/{s}", .{dir})));
    }
    mod.addIncludePath(src.path("src/common"));
    mod.addCSourceFiles(.{ .root = src.path("src"), .files = &sources, .flags = flags.items });

    const lib = c.staticLibrary("lzma", mod);
    lib.installHeader(src.path("src/liblzma/api/lzma.h"), "lzma.h");
    lib.installHeadersDirectory(src.path("src/liblzma/api/lzma"), "lzma", .{});
    return lib;
}

const sources = [_][]const u8{
    "common/tuklib_physmem.c",
    "common/tuklib_cpucores.c",
    "liblzma/check/check.c",
    "liblzma/check/crc32_fast.c",
    "liblzma/check/crc64_fast.c",
    "liblzma/check/sha256.c",
    "liblzma/common/alone_decoder.c",
    "liblzma/common/alone_encoder.c",
    "liblzma/common/auto_decoder.c",
    "liblzma/common/block_buffer_decoder.c",
    "liblzma/common/block_buffer_encoder.c",
    "liblzma/common/block_decoder.c",
    "liblzma/common/block_encoder.c",
    "liblzma/common/block_header_decoder.c",
    "liblzma/common/block_header_encoder.c",
    "liblzma/common/block_util.c",
    "liblzma/common/common.c",
    "liblzma/common/easy_buffer_encoder.c",
    "liblzma/common/easy_decoder_memusage.c",
    "liblzma/common/easy_encoder.c",
    "liblzma/common/easy_encoder_memusage.c",
    "liblzma/common/easy_preset.c",
    "liblzma/common/file_info.c",
    "liblzma/common/filter_buffer_decoder.c",
    "liblzma/common/filter_buffer_encoder.c",
    "liblzma/common/filter_common.c",
    "liblzma/common/filter_decoder.c",
    "liblzma/common/filter_encoder.c",
    "liblzma/common/filter_flags_decoder.c",
    "liblzma/common/filter_flags_encoder.c",
    "liblzma/common/hardware_cputhreads.c",
    "liblzma/common/hardware_physmem.c",
    "liblzma/common/index.c",
    "liblzma/common/index_decoder.c",
    "liblzma/common/index_encoder.c",
    "liblzma/common/index_hash.c",
    "liblzma/common/lzip_decoder.c",
    "liblzma/common/microlzma_decoder.c",
    "liblzma/common/microlzma_encoder.c",
    "liblzma/common/outqueue.c",
    "liblzma/common/stream_buffer_decoder.c",
    "liblzma/common/stream_buffer_encoder.c",
    "liblzma/common/stream_decoder.c",
    "liblzma/common/stream_decoder_mt.c",
    "liblzma/common/stream_encoder.c",
    "liblzma/common/stream_encoder_mt.c",
    "liblzma/common/stream_flags_common.c",
    "liblzma/common/stream_flags_decoder.c",
    "liblzma/common/stream_flags_encoder.c",
    "liblzma/common/string_conversion.c",
    "liblzma/common/vli_decoder.c",
    "liblzma/common/vli_encoder.c",
    "liblzma/common/vli_size.c",
    "liblzma/delta/delta_common.c",
    "liblzma/delta/delta_decoder.c",
    "liblzma/delta/delta_encoder.c",
    "liblzma/lz/lz_decoder.c",
    "liblzma/lz/lz_encoder.c",
    "liblzma/lz/lz_encoder_mf.c",
    "liblzma/lzma/fastpos_table.c",
    "liblzma/lzma/lzma2_decoder.c",
    "liblzma/lzma/lzma2_encoder.c",
    "liblzma/lzma/lzma_decoder.c",
    "liblzma/lzma/lzma_encoder.c",
    "liblzma/lzma/lzma_encoder_optimum_fast.c",
    "liblzma/lzma/lzma_encoder_optimum_normal.c",
    "liblzma/lzma/lzma_encoder_presets.c",
    "liblzma/rangecoder/price_table.c",
    "liblzma/simple/arm.c",
    "liblzma/simple/arm64.c",
    "liblzma/simple/armthumb.c",
    "liblzma/simple/ia64.c",
    "liblzma/simple/powerpc.c",
    "liblzma/simple/riscv.c",
    "liblzma/simple/simple_coder.c",
    "liblzma/simple/simple_decoder.c",
    "liblzma/simple/simple_encoder.c",
    "liblzma/simple/sparc.c",
    "liblzma/simple/x86.c",
};
