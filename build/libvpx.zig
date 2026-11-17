const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "libvpx",
    .version = "1.17.0",
    .licenses = &.{ "LICENSE", "PATENTS" },
    .ffmpeg = &.{"libvpx"},
    .system_libs = .{ .linux = &.{ "m", "pthread" } },
};

const version = Meta.versionParts(meta.version);

const Entry = struct { name: []const u8, value: u8 };

pub fn build(c: Ctx, nasm: Nasm) ?Ctx.Output {
    const b = c.b;
    const t = c.target.result;
    const src = c.upstream("libvpx");
    // Only x86_64 and non-Windows aarch64 have their SIMD ported; every other target gets libvpx's
    // generic C configuration.
    const x86_64 = t.cpu.arch == .x86_64;
    const arm64 = t.cpu.arch == .aarch64 and !c.isWindows();
    const linux = c.os() == .linux;
    const gen_dir = if (x86_64) "gen/libvpx/x86_64" else if (arm64) "gen/libvpx/arm64" else "gen/libvpx/generic";

    const entries = configEntries(b, c, x86_64, arm64);
    const generated = b.addWriteFiles();
    _ = generated.add("vpx_config.h", configHeader(b, entries));
    if (x86_64) _ = generated.add("vpx_config.asm", configAsm(b, entries));
    _ = generated.add("vpx_version.h", versionHeader(b));
    const config_c = generated.add("vpx_config.c", configSource(b, t, arm64));

    var flags: std.ArrayList([]const u8) = .empty;
    flags.append(b.allocator, "-DNDEBUG") catch @panic("OOM");
    // vpx_pthread.h's Windows trylock uses EBUSY without including errno.h.
    if (c.isWindows()) flags.appendSlice(b.allocator, &.{"--include=errno.h"}) catch @panic("OOM");
    if (linux) flags.appendSlice(b.allocator, &.{ "-U_FORTIFY_SOURCE", "-D_FORTIFY_SOURCE=0", "-D_LARGEFILE_SOURCE", "-D_FILE_OFFSET_BITS=64" }) catch @panic("OOM");

    const setup: Ctx.Setup = .{ .includes = &.{ generated.getDirectory(), b.path(gen_dir), src.path("") } };

    const mod = c.module(.{});
    setup.apply(mod);
    mod.addCSourceFiles(.{ .root = src.path(""), .files = &common_c, .flags = flags.items });
    mod.addCSourceFile(.{ .file = config_c, .flags = flags.items });

    if (x86_64) {
        // x86_64 baseline already carries mmx and sse2, so those files live in the main module.
        mod.addCSourceFiles(.{ .root = src.path(""), .files = &x86_64_c, .flags = flags.items });

        const Isa = struct { name: []const u8, features: []const std.Target.x86.Feature, files: []const []const u8 };
        const isas = [_]Isa{
            .{ .name = "vpx_ssse3", .features = &.{.ssse3}, .files = &ssse3_c },
            .{ .name = "vpx_sse4_1", .features = &.{.sse4_1}, .files = &sse4_1_c },
            .{ .name = "vpx_avx", .features = &.{.avx}, .files = &avx_c },
            .{ .name = "vpx_avx2", .features = &.{.avx2}, .files = &avx2_c },
            .{ .name = "vpx_avx512", .features = &.{ .avx512f, .avx512cd, .avx512bw, .avx512dq, .avx512vl }, .files = &avx512_c },
        };
        for (isas) |isa| {
            c.addSources(mod, isa.name, .{
                .module = .{ .x86_features = isa.features },
                .setup = setup,
                .groups = &.{.{ .root = src.path(""), .files = isa.files, .flags = flags.items }},
            });
        }

        nasm.addFiles(c, mod, .{
            .root = src.path(""),
            // Without GNU inline asm the x87 control word accessors are external asm.
            .files = if (c.isMsvc()) &(x86_64_asm ++ [_][]const u8{"vpx_ports/float_control_word.asm"}) else &x86_64_asm,
            .include_dirs = &.{ generated.getDirectory(), src.path("") },
        });
    }

    if (arm64) {
        // Same -march extensions libvpx's Makefile applies per file suffix.
        mod.addCSourceFiles(.{ .root = src.path(""), .files = &(aarch64_c ++ aarch64_neon_c), .flags = flags.items });
        const Isa = struct { name: []const u8, features: []const std.Target.aarch64.Feature, files: []const []const u8 };
        const isas = [_]Isa{
            .{ .name = "vpx_neon_dotprod", .features = &.{.dotprod}, .files = &aarch64_dotprod_c },
            .{ .name = "vpx_neon_i8mm", .features = &.{ .dotprod, .i8mm }, .files = &aarch64_i8mm_c },
            .{ .name = "vpx_sve", .features = &.{ .dotprod, .i8mm, .sve }, .files = &aarch64_sve_c },
            .{ .name = "vpx_sve2", .features = &.{ .v9a, .i8mm, .sve2 }, .files = &aarch64_sve2_c },
        };
        for (isas) |isa| {
            c.addSources(mod, isa.name, .{
                .module = .{ .aarch64_features = isa.features },
                .setup = setup,
                .groups = &.{.{ .root = src.path(""), .files = isa.files, .flags = flags.items }},
            });
        }
    }

    const lib = c.staticLibrary("vpx", mod);
    for (installed_headers) |h| lib.installHeader(src.path(b.fmt("vpx/{s}", .{h})), b.fmt("vpx/{s}", .{h}));
    return c.single(lib);
}

fn configEntries(b: *std.Build, c: Ctx, x86_64: bool, arm64: bool) []const Entry {
    const t = c.target.result;
    const windows = c.isWindows();
    var list: std.ArrayList(Entry) = .empty;
    const add = struct {
        fn f(l: *std.ArrayList(Entry), a: std.mem.Allocator, name: []const u8, value: bool) void {
            l.append(a, .{ .name = name, .value = @intFromBool(value) }) catch @panic("OOM");
        }
    }.f;
    const a = b.allocator;
    const simd = [_][]const u8{ "MMX", "SSE", "SSE2", "SSE3", "SSSE3", "SSE4_1", "AVX", "AVX2", "AVX512" };

    add(&list, a, "VPX_ARCH_ARM", arm64);
    add(&list, a, "VPX_ARCH_AARCH64", arm64);
    add(&list, a, "VPX_ARCH_MIPS", false);
    add(&list, a, "VPX_ARCH_X86", false);
    add(&list, a, "VPX_ARCH_X86_64", x86_64);
    add(&list, a, "VPX_ARCH_PPC", false);
    add(&list, a, "VPX_ARCH_LOONGARCH", false);
    add(&list, a, "HAVE_NEON_ASM", false);
    for ([_][]const u8{ "HAVE_NEON", "HAVE_NEON_DOTPROD", "HAVE_NEON_I8MM", "HAVE_SVE", "HAVE_SVE2" }) |n| add(&list, a, n, arm64);
    for ([_][]const u8{ "HAVE_MIPS32", "HAVE_DSPR2", "HAVE_MSA", "HAVE_MIPS64" }) |n| add(&list, a, n, false);
    add(&list, a, "HAVE_X86_ASM", x86_64);
    for (simd) |n| add(&list, a, b.fmt("HAVE_{s}", .{n}), x86_64);
    for ([_][]const u8{ "HAVE_VSX", "HAVE_MMI", "HAVE_LSX", "HAVE_LASX" }) |n| add(&list, a, n, false);
    add(&list, a, "HAVE_VPX_PORTS", true);
    // configure does not probe headers for Windows toolchains, so both stay off there.
    add(&list, a, "HAVE_PTHREAD_H", !windows);
    add(&list, a, "HAVE_PTHREAD_SETNAME_NP", !windows);
    add(&list, a, "HAVE_UNISTD_H", !windows);
    add(&list, a, "CONFIG_DEPENDENCY_TRACKING", true);
    add(&list, a, "CONFIG_EXTERNAL_BUILD", false);
    add(&list, a, "CONFIG_INSTALL_DOCS", false);
    add(&list, a, "CONFIG_INSTALL_BINS", false);
    add(&list, a, "CONFIG_INSTALL_LIBS", true);
    add(&list, a, "CONFIG_INSTALL_SRCS", false);
    add(&list, a, "CONFIG_DEBUG", false);
    add(&list, a, "CONFIG_GPROF", false);
    add(&list, a, "CONFIG_GCOV", false);
    add(&list, a, "CONFIG_RVCT", false);
    add(&list, a, "CONFIG_GCC", !c.isMsvc());
    add(&list, a, "CONFIG_MSVS", c.isMsvc());
    // configure leaves pic off unless the compiler defaults to PIE, which Windows toolchains do not.
    add(&list, a, "CONFIG_PIC", !windows);
    add(&list, a, "CONFIG_BIG_ENDIAN", t.cpu.arch.endian() == .big);
    add(&list, a, "CONFIG_CODEC_SRCS", false);
    add(&list, a, "CONFIG_DEBUG_LIBS", false);
    add(&list, a, "CONFIG_DEQUANT_TOKENS", false);
    add(&list, a, "CONFIG_DC_RECON", false);
    add(&list, a, "CONFIG_RUNTIME_CPU_DETECT", true);
    // configure turns postproc on for x86 toolchains only.
    add(&list, a, "CONFIG_POSTPROC", x86_64);
    add(&list, a, "CONFIG_VP9_POSTPROC", false);
    add(&list, a, "CONFIG_MULTITHREAD", true);
    add(&list, a, "CONFIG_INTERNAL_STATS", false);
    add(&list, a, "CONFIG_VP8_ENCODER", true);
    add(&list, a, "CONFIG_VP8_DECODER", true);
    add(&list, a, "CONFIG_VP9_ENCODER", true);
    add(&list, a, "CONFIG_VP9_DECODER", true);
    add(&list, a, "CONFIG_VP8", true);
    add(&list, a, "CONFIG_VP9", true);
    add(&list, a, "CONFIG_ENCODERS", true);
    add(&list, a, "CONFIG_DECODERS", true);
    add(&list, a, "CONFIG_STATIC_MSVCRT", false);
    add(&list, a, "CONFIG_SPATIAL_RESAMPLING", true);
    add(&list, a, "CONFIG_REALTIME_ONLY", false);
    add(&list, a, "CONFIG_ONTHEFLY_BITPACKING", false);
    add(&list, a, "CONFIG_ERROR_CONCEALMENT", false);
    add(&list, a, "CONFIG_SHARED", false);
    add(&list, a, "CONFIG_STATIC", true);
    add(&list, a, "CONFIG_SMALL", false);
    add(&list, a, "CONFIG_POSTPROC_VISUALIZER", false);
    add(&list, a, "CONFIG_OS_SUPPORT", true);
    add(&list, a, "CONFIG_UNIT_TESTS", false);
    add(&list, a, "CONFIG_WEBM_IO", true);
    add(&list, a, "CONFIG_LIBYUV", true);
    add(&list, a, "CONFIG_DECODE_PERF_TESTS", false);
    add(&list, a, "CONFIG_ENCODE_PERF_TESTS", false);
    add(&list, a, "CONFIG_MULTI_RES_ENCODING", false);
    add(&list, a, "CONFIG_TEMPORAL_DENOISING", true);
    add(&list, a, "CONFIG_VP9_TEMPORAL_DENOISING", false);
    add(&list, a, "CONFIG_COEFFICIENT_RANGE_CHECKING", false);
    add(&list, a, "CONFIG_VP9_HIGHBITDEPTH", true);
    add(&list, a, "CONFIG_BETTER_HW_COMPATIBILITY", false);
    add(&list, a, "CONFIG_EXPERIMENTAL", false);
    add(&list, a, "CONFIG_SIZE_LIMIT", false);
    add(&list, a, "CONFIG_ALWAYS_ADJUST_BPM", false);
    add(&list, a, "CONFIG_BITSTREAM_DEBUG", false);
    add(&list, a, "CONFIG_MISMATCH_DEBUG", false);
    add(&list, a, "CONFIG_FP_MB_STATS", false);
    add(&list, a, "CONFIG_EMULATE_HARDWARE", false);
    add(&list, a, "CONFIG_NON_GREEDY_MV", false);
    add(&list, a, "CONFIG_COLLECT_COMPONENT_TIMING", false);
    return list.items;
}

fn configHeader(b: *std.Build, entries: []const Entry) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(b.allocator, "/* Generated by build/libvpx.zig to match libvpx's configure output. */\n" ++
        "#ifndef VPX_CONFIG_H\n#define VPX_CONFIG_H\n#define RESTRICT    \n#define INLINE      inline\n") catch @panic("OOM");
    for (entries) |e| out.appendSlice(b.allocator, b.fmt("#define {s} {d}\n", .{ e.name, e.value })) catch @panic("OOM");
    out.appendSlice(b.allocator, "#endif /* VPX_CONFIG_H */\n") catch @panic("OOM");
    return out.items;
}

fn configAsm(b: *std.Build, entries: []const Entry) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (entries) |e| out.appendSlice(b.allocator, b.fmt("{s} equ {d}\n", .{ e.name, e.value })) catch @panic("OOM");
    return out.items;
}

fn versionHeader(b: *std.Build) []const u8 {
    const v = b.fmt("v{d}.{d}.{d}", .{ version[0], version[1], version[2] });
    return b.fmt(
        \\// Generated by build/libvpx.zig to match libvpx's version.sh output.
        \\#ifndef VPX_VERSION_H_
        \\#define VPX_VERSION_H_
        \\#define VERSION_MAJOR  {d}
        \\#define VERSION_MINOR  {d}
        \\#define VERSION_PATCH  {d}
        \\#define VERSION_EXTRA  ""
        \\#define VERSION_PACKED ((VERSION_MAJOR<<16)|(VERSION_MINOR<<8)|(VERSION_PATCH))
        \\#define VERSION_STRING_NOSP "{s}"
        \\#define VERSION_STRING      " {s}"
        \\#endif  // VPX_VERSION_H_
        \\
    , .{ version[0], version[1], version[2], v, v });
}

fn configSource(b: *std.Build, t: std.Target, arm64: bool) []const u8 {
    const target_name = if (t.cpu.arch == .x86_64)
        b.fmt("x86_64-{s}-gcc", .{@tagName(t.os.tag)})
    else if (arm64)
        b.fmt("arm64-{s}-gcc", .{if (t.os.tag.isDarwin()) "darwin" else @tagName(t.os.tag)})
    else
        "generic-gnu";
    return b.fmt(
        \\#include "vpx/vpx_codec.h"
        \\static const char* const cfg = "--target={s}{s} --enable-runtime-cpu-detect --enable-pic --disable-shared --enable-static --disable-examples --disable-tools --disable-docs --disable-unit-tests --disable-install-bins --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth";
        \\const char *vpx_codec_build_config(void) {{return cfg;}}
        \\
    , .{ target_name, if (t.cpu.arch == .x86_64) " --as=nasm" else "" });
}

const installed_headers = [_][]const u8{
    "vp8.h",         "vp8cx.h",       "vp8dx.h",            "vpx_codec.h",
    "vpx_decoder.h", "vpx_encoder.h", "vpx_ext_ratectrl.h", "vpx_frame_buffer.h",
    "vpx_image.h",   "vpx_integer.h", "vpx_tpl.h",
};

const common_c = [_][]const u8{
    "vp8/common/alloccommon.c",
    "vp8/common/blockd.c",
    "vp8/common/dequantize.c",
    "vp8/common/entropy.c",
    "vp8/common/entropymode.c",
    "vp8/common/entropymv.c",
    "vp8/common/extend.c",
    "vp8/common/filter.c",
    "vp8/common/findnearmv.c",
    "vp8/common/generic/systemdependent.c",
    "vp8/common/idct_blk.c",
    "vp8/common/idctllm.c",
    "vp8/common/loopfilter_filters.c",
    "vp8/common/mbpitch.c",
    "vp8/common/modecont.c",
    "vp8/common/quant_common.c",
    "vp8/common/reconinter.c",
    "vp8/common/reconintra.c",
    "vp8/common/reconintra4x4.c",
    "vp8/common/rtcd.c",
    "vp8/common/setupintrarecon.c",
    "vp8/common/swapyv12buffer.c",
    "vp8/common/treecoder.c",
    "vp8/common/vp8_loopfilter.c",
    "vp8/common/vp8_skin_detection.c",
    "vp8/decoder/dboolhuff.c",
    "vp8/decoder/decodeframe.c",
    "vp8/decoder/decodemv.c",
    "vp8/decoder/detokenize.c",
    "vp8/decoder/onyxd_if.c",
    "vp8/decoder/threading.c",
    "vp8/encoder/bitstream.c",
    "vp8/encoder/boolhuff.c",
    "vp8/encoder/copy_c.c",
    "vp8/encoder/dct.c",
    "vp8/encoder/denoising.c",
    "vp8/encoder/encodeframe.c",
    "vp8/encoder/encodeintra.c",
    "vp8/encoder/encodemb.c",
    "vp8/encoder/encodemv.c",
    "vp8/encoder/ethreading.c",
    "vp8/encoder/firstpass.c",
    "vp8/encoder/lookahead.c",
    "vp8/encoder/mcomp.c",
    "vp8/encoder/modecosts.c",
    "vp8/encoder/onyx_if.c",
    "vp8/encoder/pickinter.c",
    "vp8/encoder/picklpf.c",
    "vp8/encoder/ratectrl.c",
    "vp8/encoder/rdopt.c",
    "vp8/encoder/segmentation.c",
    "vp8/encoder/temporal_filter.c",
    "vp8/encoder/tokenize.c",
    "vp8/encoder/treewriter.c",
    "vp8/encoder/vp8_quantize.c",
    "vp8/vp8_cx_iface.c",
    "vp8/vp8_dx_iface.c",
    "vp9/common/vp9_alloccommon.c",
    "vp9/common/vp9_blockd.c",
    "vp9/common/vp9_common_data.c",
    "vp9/common/vp9_entropy.c",
    "vp9/common/vp9_entropymode.c",
    "vp9/common/vp9_entropymv.c",
    "vp9/common/vp9_filter.c",
    "vp9/common/vp9_frame_buffers.c",
    "vp9/common/vp9_idct.c",
    "vp9/common/vp9_loopfilter.c",
    "vp9/common/vp9_mvref_common.c",
    "vp9/common/vp9_pred_common.c",
    "vp9/common/vp9_quant_common.c",
    "vp9/common/vp9_reconinter.c",
    "vp9/common/vp9_reconintra.c",
    "vp9/common/vp9_rtcd.c",
    "vp9/common/vp9_scale.c",
    "vp9/common/vp9_scan.c",
    "vp9/common/vp9_seg_common.c",
    "vp9/common/vp9_thread_common.c",
    "vp9/common/vp9_tile_common.c",
    "vp9/decoder/vp9_decodeframe.c",
    "vp9/decoder/vp9_decodemv.c",
    "vp9/decoder/vp9_decoder.c",
    "vp9/decoder/vp9_detokenize.c",
    "vp9/decoder/vp9_dsubexp.c",
    "vp9/decoder/vp9_job_queue.c",
    "vp9/encoder/vp9_alt_ref_aq.c",
    "vp9/encoder/vp9_aq_360.c",
    "vp9/encoder/vp9_aq_complexity.c",
    "vp9/encoder/vp9_aq_cyclicrefresh.c",
    "vp9/encoder/vp9_aq_variance.c",
    "vp9/encoder/vp9_bitstream.c",
    "vp9/encoder/vp9_context_tree.c",
    "vp9/encoder/vp9_cost.c",
    "vp9/encoder/vp9_dct.c",
    "vp9/encoder/vp9_encodeframe.c",
    "vp9/encoder/vp9_encodemb.c",
    "vp9/encoder/vp9_encodemv.c",
    "vp9/encoder/vp9_encoder.c",
    "vp9/encoder/vp9_ethread.c",
    "vp9/encoder/vp9_ext_ratectrl.c",
    "vp9/encoder/vp9_extend.c",
    "vp9/encoder/vp9_firstpass.c",
    "vp9/encoder/vp9_frame_scale.c",
    "vp9/encoder/vp9_lookahead.c",
    "vp9/encoder/vp9_mbgraph.c",
    "vp9/encoder/vp9_mcomp.c",
    "vp9/encoder/vp9_multi_thread.c",
    "vp9/encoder/vp9_noise_estimate.c",
    "vp9/encoder/vp9_picklpf.c",
    "vp9/encoder/vp9_pickmode.c",
    "vp9/encoder/vp9_quantize.c",
    "vp9/encoder/vp9_ratectrl.c",
    "vp9/encoder/vp9_rd.c",
    "vp9/encoder/vp9_rdopt.c",
    "vp9/encoder/vp9_resize.c",
    "vp9/encoder/vp9_segmentation.c",
    "vp9/encoder/vp9_skin_detection.c",
    "vp9/encoder/vp9_speed_features.c",
    "vp9/encoder/vp9_subexp.c",
    "vp9/encoder/vp9_svc_layercontext.c",
    "vp9/encoder/vp9_temporal_filter.c",
    "vp9/encoder/vp9_tokenize.c",
    "vp9/encoder/vp9_tpl_model.c",
    "vp9/encoder/vp9_treewriter.c",
    "vp9/vp9_cx_iface.c",
    "vp9/vp9_dx_iface.c",
    "vp9/vp9_iface_common.c",
    "vpx/src/vpx_codec.c",
    "vpx/src/vpx_decoder.c",
    "vpx/src/vpx_encoder.c",
    "vpx/src/vpx_image.c",
    "vpx_dsp/avg.c",
    "vpx_dsp/bitreader.c",
    "vpx_dsp/bitreader_buffer.c",
    "vpx_dsp/bitwriter.c",
    "vpx_dsp/bitwriter_buffer.c",
    "vpx_dsp/fwd_txfm.c",
    "vpx_dsp/intrapred.c",
    "vpx_dsp/inv_txfm.c",
    "vpx_dsp/loopfilter.c",
    "vpx_dsp/prob.c",
    "vpx_dsp/psnr.c",
    "vpx_dsp/quantize.c",
    "vpx_dsp/sad.c",
    "vpx_dsp/skin_detection.c",
    "vpx_dsp/sse.c",
    "vpx_dsp/subtract.c",
    "vpx_dsp/sum_squares.c",
    "vpx_dsp/variance.c",
    "vpx_dsp/vpx_convolve.c",
    "vpx_dsp/vpx_dsp_rtcd.c",
    "vpx_mem/vpx_mem.c",
    "vpx_scale/generic/gen_scalers.c",
    "vpx_scale/generic/vpx_scale.c",
    "vpx_scale/generic/yv12config.c",
    "vpx_scale/generic/yv12extend.c",
    "vpx_scale/vpx_scale_rtcd.c",
    "vpx_util/vpx_thread.c",
    "vpx_util/vpx_write_yuv_frame.c",
};

const x86_64_c = [_][]const u8{
    "vp8/common/mfqe.c",
    "vp8/common/postproc.c",
    "vp8/common/x86/loopfilter_x86.c",
    "vp8/common/x86/vp8_asm_stubs.c",
    "vpx_dsp/add_noise.c",
    "vpx_dsp/deblock.c",
    "vp8/common/x86/bilinear_filter_sse2.c",
    "vp8/common/x86/idct_blk_sse2.c",
    "vp8/encoder/x86/denoising_sse2.c",
    "vp8/encoder/x86/vp8_enc_stubs_sse2.c",
    "vp8/encoder/x86/vp8_quantize_sse2.c",
    "vp9/common/x86/vp9_idct_intrin_sse2.c",
    "vp9/encoder/x86/vp9_dct_intrin_sse2.c",
    "vp9/encoder/x86/vp9_highbd_block_error_intrin_sse2.c",
    "vp9/encoder/x86/vp9_quantize_sse2.c",
    "vpx_dsp/x86/avg_intrin_sse2.c",
    "vpx_dsp/x86/avg_pred_sse2.c",
    "vpx_dsp/x86/fwd_txfm_sse2.c",
    "vpx_dsp/x86/highbd_idct16x16_add_sse2.c",
    "vpx_dsp/x86/highbd_idct32x32_add_sse2.c",
    "vpx_dsp/x86/highbd_idct4x4_add_sse2.c",
    "vpx_dsp/x86/highbd_idct8x8_add_sse2.c",
    "vpx_dsp/x86/highbd_intrapred_intrin_sse2.c",
    "vpx_dsp/x86/highbd_loopfilter_sse2.c",
    "vpx_dsp/x86/highbd_quantize_intrin_sse2.c",
    "vpx_dsp/x86/highbd_variance_sse2.c",
    "vpx_dsp/x86/inv_txfm_sse2.c",
    "vpx_dsp/x86/loopfilter_sse2.c",
    "vpx_dsp/x86/post_proc_sse2.c",
    "vpx_dsp/x86/quantize_sse2.c",
    "vpx_dsp/x86/sum_squares_sse2.c",
    "vpx_dsp/x86/variance_sse2.c",
    "vpx_dsp/x86/vpx_subpixel_4t_intrin_sse2.c",
    "vp8/common/x86/idct_blk_mmx.c",
};

const avx2_c = [_][]const u8{
    "vp9/encoder/x86/highbd_temporal_filter_avx2.c",
    "vp9/encoder/x86/temporal_filter_avx2.c",
    "vp9/encoder/x86/vp9_error_avx2.c",
    "vp9/encoder/x86/vp9_quantize_avx2.c",
    "vpx_dsp/x86/avg_intrin_avx2.c",
    "vpx_dsp/x86/avg_pred_avx2.c",
    "vpx_dsp/x86/highbd_convolve_avx2.c",
    "vpx_dsp/x86/highbd_intrapred_intrin_avx2.c",
    "vpx_dsp/x86/highbd_quantize_intrin_avx2.c",
    "vpx_dsp/x86/highbd_sad4d_avx2.c",
    "vpx_dsp/x86/highbd_sad_avx2.c",
    "vpx_dsp/x86/inv_txfm_avx2.c",
    "vpx_dsp/x86/loopfilter_avx2.c",
    "vpx_dsp/x86/quantize_avx2.c",
    "vpx_dsp/x86/sad4d_avx2.c",
    "vpx_dsp/x86/sad_avx2.c",
    "vpx_dsp/x86/sse_avx2.c",
    "vpx_dsp/x86/subtract_avx2.c",
    "vpx_dsp/x86/variance_avx2.c",
    "vpx_dsp/x86/vpx_subpixel_8t_intrin_avx2.c",
};

const sse4_1_c = [_][]const u8{
    "vp8/encoder/x86/quantize_sse4.c",
    "vp9/common/x86/vp9_highbd_iht16x16_add_sse4.c",
    "vp9/common/x86/vp9_highbd_iht4x4_add_sse4.c",
    "vp9/common/x86/vp9_highbd_iht8x8_add_sse4.c",
    "vp9/encoder/x86/highbd_temporal_filter_sse4.c",
    "vp9/encoder/x86/temporal_filter_sse4.c",
    "vpx_dsp/x86/highbd_idct16x16_add_sse4.c",
    "vpx_dsp/x86/highbd_idct32x32_add_sse4.c",
    "vpx_dsp/x86/highbd_idct4x4_add_sse4.c",
    "vpx_dsp/x86/highbd_idct8x8_add_sse4.c",
    "vpx_dsp/x86/sse_sse4.c",
};

const ssse3_c = [_][]const u8{
    "vp8/encoder/x86/vp8_quantize_ssse3.c",
    "vp9/encoder/x86/highbd_temporal_filter_ssse3.c",
    "vp9/encoder/x86/temporal_filter_ssse3.c",
    "vp9/encoder/x86/vp9_frame_scale_ssse3.c",
    "vp9/encoder/x86/vp9_quantize_ssse3.c",
    "vpx_dsp/x86/highbd_intrapred_intrin_ssse3.c",
    "vpx_dsp/x86/inv_txfm_ssse3.c",
    "vpx_dsp/x86/quantize_ssse3.c",
    "vpx_dsp/x86/vpx_subpixel_8t_intrin_ssse3.c",
};

const avx512_c = [_][]const u8{
    "vpx_dsp/x86/highbd_intrapred_intrin_avx512.c",
    "vpx_dsp/x86/sad4d_avx512.c",
    "vpx_dsp/x86/sad_avx512.c",
};

const avx_c = [_][]const u8{
    "vpx_dsp/x86/quantize_avx.c",
};

const x86_64_asm = [_][]const u8{
    "vp8/common/x86/dequantize_mmx.asm",
    "vp8/common/x86/idctllm_mmx.asm",
    "vp8/common/x86/idctllm_sse2.asm",
    "vp8/common/x86/iwalsh_sse2.asm",
    "vp8/common/x86/loopfilter_block_sse2_x86_64.asm",
    "vp8/common/x86/loopfilter_sse2.asm",
    "vp8/common/x86/mfqe_sse2.asm",
    "vp8/common/x86/recon_mmx.asm",
    "vp8/common/x86/recon_sse2.asm",
    "vp8/common/x86/subpixel_mmx.asm",
    "vp8/common/x86/subpixel_sse2.asm",
    "vp8/common/x86/subpixel_ssse3.asm",
    "vp8/encoder/x86/block_error_sse2.asm",
    "vp8/encoder/x86/copy_sse2.asm",
    "vp8/encoder/x86/copy_sse3.asm",
    "vp8/encoder/x86/dct_sse2.asm",
    "vp8/encoder/x86/fwalsh_sse2.asm",
    "vp8/encoder/x86/temporal_filter_apply_sse2.asm",
    "vp9/encoder/x86/vp9_dct_sse2.asm",
    "vp9/encoder/x86/vp9_error_sse2.asm",
    "vpx_dsp/x86/add_noise_sse2.asm",
    "vpx_dsp/x86/avg_ssse3_x86_64.asm",
    "vpx_dsp/x86/deblock_sse2.asm",
    "vpx_dsp/x86/fwd_txfm_ssse3_x86_64.asm",
    "vpx_dsp/x86/highbd_intrapred_sse2.asm",
    "vpx_dsp/x86/highbd_sad4d_sse2.asm",
    "vpx_dsp/x86/highbd_sad_sse2.asm",
    "vpx_dsp/x86/highbd_subpel_variance_impl_sse2.asm",
    "vpx_dsp/x86/highbd_variance_impl_sse2.asm",
    "vpx_dsp/x86/intrapred_sse2.asm",
    "vpx_dsp/x86/intrapred_ssse3.asm",
    "vpx_dsp/x86/inv_wht_sse2.asm",
    "vpx_dsp/x86/sad4d_sse2.asm",
    "vpx_dsp/x86/sad_sse2.asm",
    "vpx_dsp/x86/ssim_opt_x86_64.asm",
    "vpx_dsp/x86/subpel_variance_sse2.asm",
    "vpx_dsp/x86/subtract_sse2.asm",
    "vpx_dsp/x86/vpx_convolve_copy_sse2.asm",
    "vpx_dsp/x86/vpx_high_subpixel_8t_sse2.asm",
    "vpx_dsp/x86/vpx_high_subpixel_bilinear_sse2.asm",
    "vpx_dsp/x86/vpx_subpixel_8t_sse2.asm",
    "vpx_dsp/x86/vpx_subpixel_8t_ssse3.asm",
    "vpx_dsp/x86/vpx_subpixel_bilinear_sse2.asm",
    "vpx_dsp/x86/vpx_subpixel_bilinear_ssse3.asm",
    "vpx_ports/emms_mmx.asm",
};

const aarch64_neon_c = [_][]const u8{
    "vp8/common/arm/loopfilter_arm.c",
    "vp8/common/arm/neon/bilinearpredict_neon.c",
    "vp8/common/arm/neon/copymem_neon.c",
    "vp8/common/arm/neon/dc_only_idct_add_neon.c",
    "vp8/common/arm/neon/dequant_idct_neon.c",
    "vp8/common/arm/neon/dequantizeb_neon.c",
    "vp8/common/arm/neon/idct_blk_neon.c",
    "vp8/common/arm/neon/iwalsh_neon.c",
    "vp8/common/arm/neon/loopfiltersimplehorizontaledge_neon.c",
    "vp8/common/arm/neon/loopfiltersimpleverticaledge_neon.c",
    "vp8/common/arm/neon/mbloopfilter_neon.c",
    "vp8/common/arm/neon/shortidct4x4llm_neon.c",
    "vp8/common/arm/neon/sixtappredict_neon.c",
    "vp8/common/arm/neon/vp8_loopfilter_neon.c",
    "vp8/encoder/arm/neon/denoising_neon.c",
    "vp8/encoder/arm/neon/fastquantizeb_neon.c",
    "vp8/encoder/arm/neon/shortfdct_neon.c",
    "vp8/encoder/arm/neon/vp8_shortwalsh4x4_neon.c",
    "vp9/common/arm/neon/vp9_highbd_iht16x16_add_neon.c",
    "vp9/common/arm/neon/vp9_highbd_iht4x4_add_neon.c",
    "vp9/common/arm/neon/vp9_highbd_iht8x8_add_neon.c",
    "vp9/common/arm/neon/vp9_iht16x16_add_neon.c",
    "vp9/common/arm/neon/vp9_iht4x4_add_neon.c",
    "vp9/common/arm/neon/vp9_iht8x8_add_neon.c",
    "vp9/encoder/arm/neon/vp9_dct_neon.c",
    "vp9/encoder/arm/neon/vp9_diamond_search_sad_neon.c",
    "vp9/encoder/arm/neon/vp9_error_neon.c",
    "vp9/encoder/arm/neon/vp9_frame_scale_neon.c",
    "vp9/encoder/arm/neon/vp9_highbd_error_neon.c",
    "vp9/encoder/arm/neon/vp9_highbd_temporal_filter_neon.c",
    "vp9/encoder/arm/neon/vp9_quantize_neon.c",
    "vp9/encoder/arm/neon/vp9_temporal_filter_neon.c",
    "vpx_dsp/arm/avg_neon.c",
    "vpx_dsp/arm/avg_pred_neon.c",
    "vpx_dsp/arm/fdct16x16_neon.c",
    "vpx_dsp/arm/fdct32x32_neon.c",
    "vpx_dsp/arm/fdct4x4_neon.c",
    "vpx_dsp/arm/fdct8x8_neon.c",
    "vpx_dsp/arm/fdct_partial_neon.c",
    "vpx_dsp/arm/hadamard_neon.c",
    "vpx_dsp/arm/highbd_avg_neon.c",
    "vpx_dsp/arm/highbd_avg_pred_neon.c",
    "vpx_dsp/arm/highbd_hadamard_neon.c",
    "vpx_dsp/arm/highbd_idct16x16_add_neon.c",
    "vpx_dsp/arm/highbd_idct32x32_1024_add_neon.c",
    "vpx_dsp/arm/highbd_idct32x32_135_add_neon.c",
    "vpx_dsp/arm/highbd_idct32x32_34_add_neon.c",
    "vpx_dsp/arm/highbd_idct32x32_add_neon.c",
    "vpx_dsp/arm/highbd_idct4x4_add_neon.c",
    "vpx_dsp/arm/highbd_idct8x8_add_neon.c",
    "vpx_dsp/arm/highbd_intrapred_neon.c",
    "vpx_dsp/arm/highbd_loopfilter_neon.c",
    "vpx_dsp/arm/highbd_quantize_neon.c",
    "vpx_dsp/arm/highbd_sad4d_neon.c",
    "vpx_dsp/arm/highbd_sad_neon.c",
    "vpx_dsp/arm/highbd_sse_neon.c",
    "vpx_dsp/arm/highbd_subpel_variance_neon.c",
    "vpx_dsp/arm/highbd_variance_neon.c",
    "vpx_dsp/arm/highbd_vpx_convolve8_neon.c",
    "vpx_dsp/arm/highbd_vpx_convolve_avg_neon.c",
    "vpx_dsp/arm/highbd_vpx_convolve_copy_neon.c",
    "vpx_dsp/arm/idct16x16_1_add_neon.c",
    "vpx_dsp/arm/idct16x16_add_neon.c",
    "vpx_dsp/arm/idct32x32_135_add_neon.c",
    "vpx_dsp/arm/idct32x32_1_add_neon.c",
    "vpx_dsp/arm/idct32x32_34_add_neon.c",
    "vpx_dsp/arm/idct32x32_add_neon.c",
    "vpx_dsp/arm/idct4x4_1_add_neon.c",
    "vpx_dsp/arm/idct4x4_add_neon.c",
    "vpx_dsp/arm/idct8x8_1_add_neon.c",
    "vpx_dsp/arm/idct8x8_add_neon.c",
    "vpx_dsp/arm/intrapred_neon.c",
    "vpx_dsp/arm/loopfilter_neon.c",
    "vpx_dsp/arm/quantize_neon.c",
    "vpx_dsp/arm/sad4d_neon.c",
    "vpx_dsp/arm/sad_neon.c",
    "vpx_dsp/arm/sse_neon.c",
    "vpx_dsp/arm/subpel_variance_neon.c",
    "vpx_dsp/arm/subtract_neon.c",
    "vpx_dsp/arm/sum_squares_neon.c",
    "vpx_dsp/arm/variance_neon.c",
    "vpx_dsp/arm/vpx_convolve8_neon.c",
    "vpx_dsp/arm/vpx_convolve_avg_neon.c",
    "vpx_dsp/arm/vpx_convolve_copy_neon.c",
    "vpx_dsp/arm/vpx_convolve_neon.c",
    "vpx_dsp/arm/vpx_scaled_convolve8_neon.c",
};

const aarch64_dotprod_c = [_][]const u8{
    "vp9/encoder/arm/neon/vp9_temporal_filter_neon_dotprod.c",
    "vpx_dsp/arm/highbd_variance_neon_dotprod.c",
    "vpx_dsp/arm/sad4d_neon_dotprod.c",
    "vpx_dsp/arm/sad_neon_dotprod.c",
    "vpx_dsp/arm/sse_neon_dotprod.c",
    "vpx_dsp/arm/subpel_variance_neon_dotprod.c",
    "vpx_dsp/arm/variance_neon_dotprod.c",
    "vpx_dsp/arm/vpx_convolve8_neon_dotprod.c",
};

const aarch64_i8mm_c = [_][]const u8{
    "vp9/encoder/arm/neon/vp9_temporal_filter_neon_i8mm.c",
    "vpx_dsp/arm/vpx_convolve8_neon_i8mm.c",
};

const aarch64_sve_c = [_][]const u8{
    "vp9/encoder/arm/neon/vp9_error_sve.c",
    "vpx_dsp/arm/highbd_variance_sve.c",
    "vpx_dsp/arm/highbd_vpx_convolve8_sve.c",
    "vpx_dsp/arm/sum_squares_sve.c",
};

const aarch64_sve2_c = [_][]const u8{
    "vp9/encoder/arm/neon/vp9_highbd_temporal_filter_sve2.c",
    "vpx_dsp/arm/highbd_vpx_convolve8_sve2.c",
};

const aarch64_c = [_][]const u8{
    "vpx_ports/aarch64_cpudetect.c",
};
