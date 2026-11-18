const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "libaom",
    .version = "3.15.3",
    .licenses = &.{ "LICENSE", "PATENTS" },
    .spdx = "BSD-2-Clause",
    .ffmpeg = &.{"libaom"},
    .system_libs = .{ .linux = &.{ "m", "pthread" } },
};

pub fn build(c: Ctx, nasm: Nasm) ?Ctx.Output {
    const b = c.b;
    const arch = c.arch();
    const x86_64 = arch == .x86_64;
    const x86 = arch == .x86;
    const arm64 = arch.isAARCH64();
    const windows = c.isWindows();
    const src = c.upstream("libaom");
    const gen_arch = if (x86_64) "x86_64" else if (x86) "x86" else if (arm64) "arm64" else "generic";

    const generated = b.addWriteFiles();
    _ = generated.add("config/aom_config.h", configHeader(c));
    _ = generated.add("config/aom_config.asm", configAsm(c));
    _ = generated.add("config/aom_config.c",
        \\#include "aom/aom_codec.h"
        \\static const char* const cfg = "zig build, parity with cmake -DCONFIG_RUNTIME_CPU_DETECT=1";
        \\const char *aom_codec_build_config(void) {return cfg;}
        \\
    );
    const ver = Meta.versionParts(meta.version);
    _ = generated.add("config/aom_version.h", b.fmt(
        \\#ifndef AOM_VERSION_H_
        \\#define AOM_VERSION_H_
        \\#define VERSION_MAJOR {d}
        \\#define VERSION_MINOR {d}
        \\#define VERSION_PATCH {d}
        \\#define VERSION_EXTRA ""
        \\#define VERSION_PACKED \
        \\  ((VERSION_MAJOR << 16) | (VERSION_MINOR << 8) | (VERSION_PATCH))
        \\#define VERSION_STRING_NOSP "v{s}"
        \\#define VERSION_STRING " v{s}"
        \\#endif  // AOM_VERSION_H_
        \\
    , .{ ver[0], ver[1], ver[2], meta.version, meta.version }));
    for ([_][]const u8{ "aom_dsp_rtcd.h", "aom_scale_rtcd.h", "av1_rtcd.h" }) |name| {
        _ = generated.addCopyFile(
            b.path(b.fmt("gen/libaom/{s}/{s}", .{ gen_arch, name })),
            b.fmt("config/{s}", .{name}),
        );
    }

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{ "-DNDEBUG", "-std=c11", "-D_FILE_OFFSET_BITS=64", "-D_LARGEFILE_SOURCE" }) catch @panic("OOM");
    if (windows) flags.appendSlice(b.allocator, &.{ "-D_WIN32_WINNT=0x0601", "-D_CRT_SECURE_NO_WARNINGS" }) catch @panic("OOM");

    const setup: Ctx.Setup = .{ .includes = &.{ generated.getDirectory(), src.path("") } };
    const mod = c.module(.{});
    setup.apply(mod);
    mod.addCSourceFiles(.{ .root = src.path(""), .files = &common, .flags = flags.items });
    mod.addCSourceFiles(.{ .root = generated.getDirectory(), .files = &.{"config/aom_config.c"}, .flags = flags.items });

    const isa: Isa = .{ .c = c, .into = mod, .src = src, .setup = setup, .flags = flags.items };

    if (x86 or x86_64) {
        const X86 = struct { name: []const u8, features: []const std.Target.x86.Feature, files: []const []const u8 };
        const isas = [_]X86{
            .{ .name = "sse2", .features = &.{.sse2}, .files = &sse2_files },
            .{ .name = "sse3", .features = &.{.sse3}, .files = &sse3_files },
            .{ .name = "ssse3", .features = &.{.ssse3}, .files = if (x86) &(ssse3_files ++ x86_ssse3_files) else &ssse3_files },
            .{ .name = "sse4_1", .features = &.{.sse4_1}, .files = &sse4_1_files },
            .{ .name = "sse4_2", .features = &.{.sse4_2}, .files = &sse4_2_files },
            .{ .name = "avx", .features = &.{.avx}, .files = &avx_files },
            .{ .name = "avx2", .features = &.{.avx2}, .files = &avx2_files },
        };
        for (isas) |x| isa.add(x.name, .{ .x86 = x.features }, x.files);

        var asm_files: std.ArrayList([]const u8) = .empty;
        asm_files.appendSlice(b.allocator, &x86_asm) catch @panic("OOM");
        if (x86_64) asm_files.appendSlice(b.allocator, &x86_64_asm) catch @panic("OOM");
        if (windows and x86_64) asm_files.append(b.allocator, "aom_ports/float.asm") catch @panic("OOM");
        nasm.addFiles(c, mod, .{
            .root = src.path(""),
            .files = asm_files.items,
            .include_dirs = &.{ src.path(""), generated.getDirectory() },
            .flags = if (windows) &.{} else &.{"-DPIC"},
        });
    }

    if (arm64) {
        const Arm = struct { name: []const u8, features: []const std.Target.aarch64.Feature, files: []const []const u8 };
        const isas = [_]Arm{
            .{ .name = "crc", .features = &.{.crc}, .files = &crc_files },
            .{ .name = "dotprod", .features = &.{.dotprod}, .files = &dotprod_files },
            .{ .name = "i8mm", .features = &.{ .dotprod, .i8mm }, .files = &i8mm_files },
            .{ .name = "sve", .features = &.{ .dotprod, .i8mm, .sve }, .files = &sve_files },
            .{ .name = "sve2", .features = &.{ .v9a, .i8mm, .sve2 }, .files = &sve2_files },
        };
        mod.addCSourceFiles(.{ .root = src.path(""), .files = &aarch64_files, .flags = flags.items });
        for (isas) |a| isa.add(a.name, .{ .arm = a.features }, a.files);
    }

    const lib = c.staticLibrary("aom", mod);
    for (public_headers) |h| lib.installHeader(src.path(b.fmt("aom/{s}", .{h})), b.fmt("aom/{s}", .{h}));
    return c.single(lib);
}

const Features = union(enum) {
    x86: []const std.Target.x86.Feature,
    arm: []const std.Target.aarch64.Feature,
};

/// Compiles sources that need extra CPU features into objects of the library.
const Isa = struct {
    c: Ctx,
    into: *std.Build.Module,
    src: *std.Build.Dependency,
    setup: Ctx.Setup,
    flags: []const []const u8,

    fn add(isa: Isa, name: []const u8, features: Features, files: []const []const u8) void {
        isa.c.addSources(isa.into, isa.c.b.fmt("aom_{s}", .{name}), .{
            .module = switch (features) {
                .x86 => |f| .{ .x86_features = f },
                .arm => |f| .{ .aarch64_features = f },
            },
            .setup = isa.setup,
            .groups = &.{.{ .root = isa.src.path(""), .files = files, .flags = isa.flags }},
        });
    }
};

const Entry = struct { []const u8, u8 };

fn b10(v: bool) u8 {
    return @intFromBool(v);
}

fn configEntries(c: Ctx) []const Entry {
    const t = c.target.result;
    const x86 = t.cpu.arch.isX86();
    const arm64 = t.cpu.arch.isAARCH64();
    const windows = c.isWindows();
    const os_support = switch (t.os.tag) {
        .linux, .macos, .windows => true,
        else => false,
    };
    const entries = [_]Entry{
        .{ "AOM_ARCH_AARCH64", b10(arm64) },
        .{ "AOM_ARCH_ARM", b10(arm64) },
        .{ "AOM_ARCH_PPC", 0 },
        .{ "AOM_ARCH_RISCV", 0 },
        .{ "AOM_ARCH_X86", b10(t.cpu.arch == .x86) },
        .{ "AOM_ARCH_X86_64", b10(t.cpu.arch == .x86_64) },
        .{ "CONFIG_ACCOUNTING", 0 },
        .{ "CONFIG_ANALYZER", 0 },
        .{ "CONFIG_AV1_DECODER", 1 },
        .{ "CONFIG_AV1_ENCODER", 1 },
        .{ "CONFIG_AV1_HIGHBITDEPTH", 1 },
        .{ "CONFIG_AV1_TEMPORAL_DENOISING", 0 },
        .{ "CONFIG_BIG_ENDIAN", b10(t.cpu.arch.endian() == .big) },
        .{ "CONFIG_BITRATE_ACCURACY", 0 },
        .{ "CONFIG_BITRATE_ACCURACY_BL", 0 },
        .{ "CONFIG_BITSTREAM_DEBUG", 0 },
        .{ "CONFIG_COEFFICIENT_RANGE_CHECKING", 0 },
        .{ "CONFIG_COLLECT_COMPONENT_TIMING", 0 },
        .{ "CONFIG_COLLECT_PARTITION_STATS", 0 },
        .{ "CONFIG_COLLECT_RD_STATS", 0 },
        .{ "CONFIG_CWG_C013", 0 },
        .{ "CONFIG_CWG_E050", 0 },
        .{ "CONFIG_DEBUG", 0 },
        .{ "CONFIG_DENOISE", 1 },
        .{ "CONFIG_DISABLE_FULL_PIXEL_SPLIT_8X8", 1 },
        .{ "CONFIG_ENTROPY_STATS", 0 },
        .{ "CONFIG_EXCLUDE_SIMD_MISMATCH", 0 },
        .{ "CONFIG_FPMT_TEST", 0 },
        .{ "CONFIG_GCC", 1 },
        .{ "CONFIG_GCOV", 0 },
        .{ "CONFIG_GPROF", 0 },
        .{ "CONFIG_HIGHWAY", 0 },
        .{ "CONFIG_INSPECTION", 0 },
        .{ "CONFIG_INTERNAL_STATS", 0 },
        .{ "CONFIG_INTER_STATS_ONLY", 0 },
        .{ "CONFIG_LIBVMAF_PSNR_PEAK", 1 },
        .{ "CONFIG_LIBYUV", 1 },
        .{ "CONFIG_MAX_DECODE_PROFILE", 2 },
        .{ "CONFIG_MISMATCH_DEBUG", 0 },
        .{ "CONFIG_MULTITHREAD", 1 },
        .{ "CONFIG_NN_V2", 0 },
        .{ "CONFIG_NORMAL_TILE_MODE", 0 },
        .{ "CONFIG_OPTICAL_FLOW_API", 0 },
        .{ "CONFIG_OS_SUPPORT", b10(os_support) },
        .{ "CONFIG_OUTPUT_FRAME_SIZE", 0 },
        .{ "CONFIG_PARTITION_SEARCH_ORDER", 0 },
        .{ "CONFIG_PIC", b10(!windows) },
        .{ "CONFIG_QUANT_MATRIX", 1 },
        .{ "CONFIG_RATECTRL_LOG", 0 },
        .{ "CONFIG_RD_COMMAND", 0 },
        .{ "CONFIG_RD_DEBUG", 0 },
        .{ "CONFIG_REALTIME_ONLY", 0 },
        .{ "CONFIG_RT_ML_PARTITIONING", 0 },
        .{ "CONFIG_RUNTIME_CPU_DETECT", 1 },
        .{ "CONFIG_SALIENCY_MAP", 0 },
        .{ "CONFIG_SHARED", 0 },
        .{ "CONFIG_SIZE_LIMIT", 0 },
        .{ "CONFIG_SPEED_STATS", 0 },
        .{ "CONFIG_TFLITE", 0 },
        .{ "CONFIG_THREE_PASS", 0 },
        .{ "CONFIG_TUNE_BUTTERAUGLI", 0 },
        .{ "CONFIG_TUNE_VMAF", 0 },
        .{ "CONFIG_WEBM_IO", 1 },
        .{ "DECODE_HEIGHT_LIMIT", 0 },
        .{ "DECODE_WIDTH_LIMIT", 0 },
        .{ "FORCE_HIGHBITDEPTH_DECODING", 0 },
        .{ "HAVE_ARM_CRC32", b10(arm64) },
        .{ "HAVE_AVX", b10(x86) },
        .{ "HAVE_AVX2", b10(x86) },
        .{ "HAVE_AVX512", b10(t.cpu.arch == .x86_64) },
        .{ "HAVE_FEXCEPT", b10(t.os.tag == .linux and t.abi.isGnu()) },
        .{ "HAVE_MMX", b10(x86) },
        .{ "HAVE_NEON", b10(arm64) },
        .{ "HAVE_NEON_DOTPROD", b10(arm64) },
        .{ "HAVE_NEON_I8MM", b10(arm64) },
        .{ "HAVE_PTHREAD_H", b10(!windows) },
        .{ "HAVE_PTHREAD_SETNAME_NP", b10(!windows) },
        .{ "HAVE_RVV", 0 },
        .{ "HAVE_SSE", b10(x86) },
        .{ "HAVE_SSE2", b10(x86) },
        .{ "HAVE_SSE3", b10(x86) },
        .{ "HAVE_SSE4_1", b10(x86) },
        .{ "HAVE_SSE4_2", b10(x86) },
        .{ "HAVE_SSSE3", b10(x86) },
        .{ "HAVE_SVE", b10(arm64) },
        .{ "HAVE_SVE2", b10(arm64) },
        .{ "HAVE_UNISTD_H", b10(!c.isMsvc()) },
        .{ "HAVE_VSX", 0 },
        .{ "HAVE_WXWIDGETS", 0 },
        .{ "STATIC_LINK_JXL", 0 },
    };
    return c.b.allocator.dupe(Entry, &entries) catch @panic("OOM");
}

fn configHeader(c: Ctx) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(c.b.allocator, "#ifndef AOM_CONFIG_H_\n#define AOM_CONFIG_H_\n") catch @panic("OOM");
    for (configEntries(c)) |e| {
        out.appendSlice(c.b.allocator, c.b.fmt("#define {s} {d}\n", .{ e[0], e[1] })) catch @panic("OOM");
    }
    out.appendSlice(c.b.allocator, "#endif  // AOM_CONFIG_H_\n") catch @panic("OOM");
    return out.items;
}

fn configAsm(c: Ctx) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (configEntries(c)) |e| {
        out.appendSlice(c.b.allocator, c.b.fmt("{s} equ {d}\n", .{ e[0], e[1] })) catch @panic("OOM");
    }
    return out.items;
}

const public_headers = [_][]const u8{
    "aom.h",              "aom_codec.h", "aom_decoder.h", "aom_encoder.h", "aom_external_partition.h",
    "aom_frame_buffer.h", "aom_image.h", "aom_integer.h", "aomcx.h",       "aomdx.h",
    "aom_ext_ratectrl.h", "aom_tpl.h",
};

const x86_asm = [_][]const u8{
    "aom_dsp/x86/aom_high_subpixel_8t_sse2.asm",
    "aom_dsp/x86/aom_high_subpixel_bilinear_sse2.asm",
    "aom_dsp/x86/aom_subpixel_8t_ssse3.asm",
    "aom_dsp/x86/aom_subpixel_bilinear_ssse3.asm",
    "aom_dsp/x86/highbd_intrapred_asm_sse2.asm",
    "aom_dsp/x86/highbd_sad4d_sse2.asm",
    "aom_dsp/x86/highbd_sad_sse2.asm",
    "aom_dsp/x86/highbd_subpel_variance_impl_sse2.asm",
    "aom_dsp/x86/highbd_variance_impl_sse2.asm",
    "aom_dsp/x86/intrapred_asm_sse2.asm",
    "aom_dsp/x86/sad4d_sse2.asm",
    "aom_dsp/x86/sad_sse2.asm",
    "aom_dsp/x86/subpel_variance_ssse3.asm",
    "aom_dsp/x86/subtract_sse2.asm",
    "av1/encoder/x86/dct_sse2.asm",
    "av1/encoder/x86/error_sse2.asm",
};

const x86_ssse3_files = [_][]const u8{"av1/common/x86/cdef_block_ssse3.c"};

const x86_64_asm = [_][]const u8{
    "aom_dsp/x86/fwd_txfm_ssse3_x86_64.asm",
    "aom_dsp/x86/quantize_ssse3_x86_64.asm",
    "aom_dsp/x86/ssim_sse2_x86_64.asm",
    "av1/encoder/x86/av1_quantize_ssse3_x86_64.asm",
};

const common = [_][]const u8{
    "aom/src/aom_codec.c",                "aom/src/aom_decoder.c",                     "aom/src/aom_encoder.c",
    "aom/src/aom_image.c",                "aom/src/aom_integer.c",                     "aom_dsp/aom_convolve.c",
    "aom_dsp/aom_dsp_rtcd.c",             "aom_dsp/avg.c",                             "aom_dsp/binary_codes_reader.c",
    "aom_dsp/binary_codes_writer.c",      "aom_dsp/bitreader.c",                       "aom_dsp/bitreader_buffer.c",
    "aom_dsp/bitwriter.c",                "aom_dsp/bitwriter_buffer.c",                "aom_dsp/blend_a64_hmask.c",
    "aom_dsp/blend_a64_mask.c",           "aom_dsp/blend_a64_vmask.c",                 "aom_dsp/blk_sse_sum.c",
    "aom_dsp/entcode.c",                  "aom_dsp/entdec.c",                          "aom_dsp/entenc.c",
    "aom_dsp/fft.c",                      "aom_dsp/flow_estimation/corner_detect.c",   "aom_dsp/flow_estimation/corner_match.c",
    "aom_dsp/flow_estimation/disflow.c",  "aom_dsp/flow_estimation/flow_estimation.c", "aom_dsp/flow_estimation/ransac.c",
    "aom_dsp/fwd_txfm.c",                 "aom_dsp/grain_table.c",                     "aom_dsp/intrapred.c",
    "aom_dsp/loopfilter.c",               "aom_dsp/noise_model.c",                     "aom_dsp/noise_util.c",
    "aom_dsp/odintrin.c",                 "aom_dsp/psnr.c",                            "aom_dsp/pyramid.c",
    "aom_dsp/quantize.c",                 "aom_dsp/sad.c",                             "aom_dsp/sad_av1.c",
    "aom_dsp/sse.c",                      "aom_dsp/ssim.c",                            "aom_dsp/subtract.c",
    "aom_dsp/sum_squares.c",              "aom_dsp/variance.c",                        "aom_mem/aom_mem.c",
    "aom_scale/aom_scale_rtcd.c",         "aom_scale/generic/yv12config.c",            "aom_scale/generic/yv12extend.c",
    "aom_util/aom_thread.c",              "av1/arg_defs.c",                            "av1/av1_cx_iface.c",
    "av1/av1_dx_iface.c",                 "av1/common/alloccommon.c",                  "av1/common/av1_inv_txfm1d.c",
    "av1/common/av1_inv_txfm2d.c",        "av1/common/av1_loopfilter.c",               "av1/common/av1_rtcd.c",
    "av1/common/av1_txfm.c",              "av1/common/blockd.c",                       "av1/common/cdef.c",
    "av1/common/cdef_block.c",            "av1/common/cfl.c",                          "av1/common/common_data.c",
    "av1/common/convolve.c",              "av1/common/debugmodes.c",                   "av1/common/entropy.c",
    "av1/common/entropymode.c",           "av1/common/entropymv.c",                    "av1/common/frame_buffers.c",
    "av1/common/idct.c",                  "av1/common/mvref_common.c",                 "av1/common/obu_util.c",
    "av1/common/pred_common.c",           "av1/common/quant_common.c",                 "av1/common/reconinter.c",
    "av1/common/reconintra.c",            "av1/common/resize.c",                       "av1/common/restoration.c",
    "av1/common/scale.c",                 "av1/common/scan.c",                         "av1/common/seg_common.c",
    "av1/common/thread_common.c",         "av1/common/tile_common.c",                  "av1/common/timing.c",
    "av1/common/txb_common.c",            "av1/common/warped_motion.c",                "av1/decoder/decodeframe.c",
    "av1/decoder/decodemv.c",             "av1/decoder/decoder.c",                     "av1/decoder/decodetxb.c",
    "av1/decoder/detokenize.c",           "av1/decoder/grain_synthesis.c",             "av1/decoder/obu.c",
    "av1/encoder/allintra_vis.c",         "av1/encoder/aq_complexity.c",               "av1/encoder/aq_cyclicrefresh.c",
    "av1/encoder/aq_variance.c",          "av1/encoder/av1_ext_ratectrl.c",            "av1/encoder/av1_fwd_txfm1d.c",
    "av1/encoder/av1_fwd_txfm2d.c",       "av1/encoder/av1_noise_estimate.c",          "av1/encoder/av1_quantize.c",
    "av1/encoder/bitstream.c",            "av1/encoder/cnn.c",                         "av1/encoder/compound_type.c",
    "av1/encoder/context_tree.c",         "av1/encoder/cost.c",                        "av1/encoder/dwt.c",
    "av1/encoder/encode_strategy.c",      "av1/encoder/encodeframe.c",                 "av1/encoder/encodeframe_utils.c",
    "av1/encoder/encodemb.c",             "av1/encoder/encodemv.c",                    "av1/encoder/encoder.c",
    "av1/encoder/encoder_utils.c",        "av1/encoder/encodetxb.c",                   "av1/encoder/ethread.c",
    "av1/encoder/extend.c",               "av1/encoder/external_partition.c",          "av1/encoder/firstpass.c",
    "av1/encoder/global_motion.c",        "av1/encoder/global_motion_facade.c",        "av1/encoder/gop_structure.c",
    "av1/encoder/hash.c",                 "av1/encoder/hash_motion.c",                 "av1/encoder/hybrid_fwd_txfm.c",
    "av1/encoder/interp_search.c",        "av1/encoder/intra_mode_search.c",           "av1/encoder/level.c",
    "av1/encoder/lookahead.c",            "av1/encoder/mcomp.c",                       "av1/encoder/ml.c",
    "av1/encoder/motion_search_facade.c", "av1/encoder/mv_prec.c",                     "av1/encoder/nonrd_opt.c",
    "av1/encoder/nonrd_pickmode.c",       "av1/encoder/palette.c",                     "av1/encoder/partition_search.c",
    "av1/encoder/partition_strategy.c",   "av1/encoder/pass2_strategy.c",              "av1/encoder/pickcdef.c",
    "av1/encoder/picklpf.c",              "av1/encoder/pickrst.c",                     "av1/encoder/ratectrl.c",
    "av1/encoder/rd.c",                   "av1/encoder/rdopt.c",                       "av1/encoder/reconinter_enc.c",
    "av1/encoder/segmentation.c",         "av1/encoder/speed_features.c",              "av1/encoder/superres_scale.c",
    "av1/encoder/svc_layercontext.c",     "av1/encoder/temporal_filter.c",             "av1/encoder/tokenize.c",
    "av1/encoder/tpl_model.c",            "av1/encoder/tx_search.c",                   "av1/encoder/txb_rdopt.c",
    "av1/encoder/var_based_part.c",       "av1/encoder/wedge_utils.c",                 "common/args_helper.c",
    "third_party/fastfeat/fast.c",        "third_party/fastfeat/fast_9.c",             "third_party/fastfeat/nonmax.c",
    "third_party/vector/vector.c",
};

const sse2_files = [_][]const u8{
    "aom_dsp/x86/adaptive_quantize_sse2.c",          "aom_dsp/x86/aom_convolve_copy_sse2.c",      "aom_dsp/x86/avg_intrin_sse2.c",
    "aom_dsp/x86/blk_sse_sum_sse2.c",                "aom_dsp/x86/fft_sse2.c",                    "aom_dsp/x86/fwd_txfm_sse2.c",
    "aom_dsp/x86/highbd_adaptive_quantize_sse2.c",   "aom_dsp/x86/highbd_convolve_sse2.c",        "aom_dsp/x86/highbd_intrapred_sse2.c",
    "aom_dsp/x86/highbd_loopfilter_sse2.c",          "aom_dsp/x86/highbd_quantize_intrin_sse2.c", "aom_dsp/x86/highbd_subtract_sse2.c",
    "aom_dsp/x86/highbd_variance_sse2.c",            "aom_dsp/x86/intrapred_sse2.c",              "aom_dsp/x86/loopfilter_sse2.c",
    "aom_dsp/x86/quantize_sse2.c",                   "aom_dsp/x86/sum_squares_sse2.c",            "aom_dsp/x86/variance_sse2.c",
    "av1/common/x86/cfl_sse2.c",                     "av1/common/x86/convolve_2d_sse2.c",         "av1/common/x86/convolve_sse2.c",
    "av1/common/x86/jnt_convolve_sse2.c",            "av1/common/x86/resize_sse2.c",              "av1/common/x86/wiener_convolve_sse2.c",
    "av1/encoder/x86/av1_fwd_txfm_sse2.c",           "av1/encoder/x86/av1_k_means_sse2.c",        "av1/encoder/x86/av1_quantize_sse2.c",
    "av1/encoder/x86/encodetxb_sse2.c",              "av1/encoder/x86/error_intrin_sse2.c",       "av1/encoder/x86/highbd_block_error_intrin_sse2.c",
    "av1/encoder/x86/highbd_temporal_filter_sse2.c", "av1/encoder/x86/model_rd_sse2.c",           "av1/encoder/x86/reconinter_enc_sse2.c",
    "av1/encoder/x86/temporal_filter_sse2.c",        "av1/encoder/x86/wedge_utils_sse2.c",
};

const sse3_files = [_][]const u8{
    "av1/encoder/x86/ml_sse3.c",
};

const ssse3_files = [_][]const u8{
    "aom_dsp/x86/aom_subpixel_8t_intrin_ssse3.c", "aom_dsp/x86/highbd_convolve_ssse3.c",        "aom_dsp/x86/intrapred_ssse3.c",
    "aom_dsp/x86/masked_sad_intrin_ssse3.c",      "aom_dsp/x86/masked_variance_intrin_ssse3.c", "aom_dsp/x86/quantize_ssse3.c",
    "aom_dsp/x86/variance_impl_ssse3.c",          "aom_dsp/x86/variance_ssse3.c",               "av1/common/x86/av1_inv_txfm_ssse3.c",
    "av1/common/x86/cfl_ssse3.c",                 "av1/common/x86/highbd_convolve_2d_ssse3.c",  "av1/common/x86/highbd_wiener_convolve_ssse3.c",
    "av1/common/x86/jnt_convolve_ssse3.c",        "av1/common/x86/reconinter_ssse3.c",          "av1/common/x86/resize_ssse3.c",
};

const sse4_1_files = [_][]const u8{
    "aom_dsp/flow_estimation/x86/corner_match_sse4.c", "aom_dsp/flow_estimation/x86/disflow_sse4.c", "aom_dsp/x86/avg_intrin_sse4.c",
    "aom_dsp/x86/blend_a64_hmask_sse4.c",              "aom_dsp/x86/blend_a64_mask_sse4.c",          "aom_dsp/x86/blend_a64_vmask_sse4.c",
    "aom_dsp/x86/highbd_variance_sse4.c",              "aom_dsp/x86/intrapred_sse4.c",               "aom_dsp/x86/obmc_sad_sse4.c",
    "aom_dsp/x86/obmc_variance_sse4.c",                "aom_dsp/x86/sse_sse4.c",                     "av1/common/x86/av1_convolve_horiz_rs_sse4.c",
    "av1/common/x86/av1_convolve_scale_sse4.c",        "av1/common/x86/av1_txfm_sse4.c",             "av1/common/x86/cdef_block_sse4.c",
    "av1/common/x86/filterintra_sse4.c",               "av1/common/x86/highbd_convolve_2d_sse4.c",   "av1/common/x86/highbd_inv_txfm_sse4.c",
    "av1/common/x86/highbd_jnt_convolve_sse4.c",       "av1/common/x86/highbd_warp_plane_sse4.c",    "av1/common/x86/intra_edge_sse4.c",
    "av1/common/x86/reconinter_sse4.c",                "av1/common/x86/selfguided_sse4.c",           "av1/common/x86/warp_plane_sse4.c",
    "av1/encoder/x86/av1_fwd_txfm1d_sse4.c",           "av1/encoder/x86/av1_fwd_txfm2d_sse4.c",      "av1/encoder/x86/av1_highbd_quantize_sse4.c",
    "av1/encoder/x86/encodetxb_sse4.c",                "av1/encoder/x86/highbd_fwd_txfm_sse4.c",     "av1/encoder/x86/pickrst_sse4.c",
    "av1/encoder/x86/rdopt_sse4.c",
};

const sse4_2_files = [_][]const u8{
    "av1/encoder/x86/hash_sse42.c",
};

const avx_files = [_][]const u8{
    "aom_dsp/x86/aom_quantize_avx.c",
};

const avx2_files = [_][]const u8{
    "aom_dsp/flow_estimation/x86/corner_match_avx2.c", "aom_dsp/flow_estimation/x86/disflow_avx2.c",       "aom_dsp/x86/adaptive_quantize_avx2.c",
    "aom_dsp/x86/aom_convolve_copy_avx2.c",            "aom_dsp/x86/aom_subpixel_8t_intrin_avx2.c",        "aom_dsp/x86/avg_intrin_avx2.c",
    "aom_dsp/x86/blend_a64_mask_avx2.c",               "aom_dsp/x86/blk_sse_sum_avx2.c",                   "aom_dsp/x86/fft_avx2.c",
    "aom_dsp/x86/highbd_adaptive_quantize_avx2.c",     "aom_dsp/x86/highbd_convolve_avx2.c",               "aom_dsp/x86/highbd_loopfilter_avx2.c",
    "aom_dsp/x86/highbd_quantize_intrin_avx2.c",       "aom_dsp/x86/highbd_sad_avx2.c",                    "aom_dsp/x86/highbd_variance_avx2.c",
    "aom_dsp/x86/intrapred_avx2.c",                    "aom_dsp/x86/loopfilter_avx2.c",                    "aom_dsp/x86/masked_sad_intrin_avx2.c",
    "aom_dsp/x86/obmc_sad_avx2.c",                     "aom_dsp/x86/obmc_variance_avx2.c",                 "aom_dsp/x86/quantize_avx2.c",
    "aom_dsp/x86/sad4d_avx2.c",                        "aom_dsp/x86/sad_avx2.c",                           "aom_dsp/x86/sad_impl_avx2.c",
    "aom_dsp/x86/sse_avx2.c",                          "aom_dsp/x86/subtract_avx2.c",                      "aom_dsp/x86/sum_squares_avx2.c",
    "aom_dsp/x86/variance_avx2.c",                     "aom_dsp/x86/variance_impl_avx2.c",                 "av1/common/x86/av1_inv_txfm_avx2.c",
    "av1/common/x86/cdef_block_avx2.c",                "av1/common/x86/cfl_avx2.c",                        "av1/common/x86/convolve_2d_avx2.c",
    "av1/common/x86/convolve_avx2.c",                  "av1/common/x86/highbd_convolve_2d_avx2.c",         "av1/common/x86/highbd_inv_txfm_avx2.c",
    "av1/common/x86/highbd_jnt_convolve_avx2.c",       "av1/common/x86/highbd_warp_affine_avx2.c",         "av1/common/x86/highbd_wiener_convolve_avx2.c",
    "av1/common/x86/jnt_convolve_avx2.c",              "av1/common/x86/reconinter_avx2.c",                 "av1/common/x86/resize_avx2.c",
    "av1/common/x86/selfguided_avx2.c",                "av1/common/x86/warp_plane_avx2.c",                 "av1/common/x86/wiener_convolve_avx2.c",
    "av1/encoder/x86/av1_fwd_txfm2d_avx2.c",           "av1/encoder/x86/av1_highbd_quantize_avx2.c",       "av1/encoder/x86/av1_k_means_avx2.c",
    "av1/encoder/x86/av1_quantize_avx2.c",             "av1/encoder/x86/cnn_avx2.c",                       "av1/encoder/x86/encodetxb_avx2.c",
    "av1/encoder/x86/error_intrin_avx2.c",             "av1/encoder/x86/highbd_block_error_intrin_avx2.c", "av1/encoder/x86/highbd_fwd_txfm_avx2.c",
    "av1/encoder/x86/highbd_temporal_filter_avx2.c",   "av1/encoder/x86/ml_avx2.c",                        "av1/encoder/x86/pickrst_avx2.c",
    "av1/encoder/x86/rdopt_avx2.c",                    "av1/encoder/x86/temporal_filter_avx2.c",           "av1/encoder/x86/wedge_utils_avx2.c",
};

const aarch64_files = [_][]const u8{
    "aom_dsp/arm/aom_convolve8_neon.c",               "aom_dsp/arm/aom_convolve_copy_neon.c",           "aom_dsp/arm/aom_scaled_convolve8_neon.c",
    "aom_dsp/arm/avg_neon.c",                         "aom_dsp/arm/avg_pred_neon.c",                    "aom_dsp/arm/blend_a64_mask_neon.c",
    "aom_dsp/arm/blk_sse_sum_neon.c",                 "aom_dsp/arm/fwd_txfm_neon.c",                    "aom_dsp/arm/hadamard_neon.c",
    "aom_dsp/arm/highbd_avg_neon.c",                  "aom_dsp/arm/highbd_avg_pred_neon.c",             "aom_dsp/arm/highbd_blend_a64_hmask_neon.c",
    "aom_dsp/arm/highbd_blend_a64_mask_neon.c",       "aom_dsp/arm/highbd_blend_a64_vmask_neon.c",      "aom_dsp/arm/highbd_convolve8_neon.c",
    "aom_dsp/arm/highbd_hadamard_neon.c",             "aom_dsp/arm/highbd_intrapred_neon.c",            "aom_dsp/arm/highbd_loopfilter_neon.c",
    "aom_dsp/arm/highbd_masked_sad_neon.c",           "aom_dsp/arm/highbd_obmc_sad_neon.c",             "aom_dsp/arm/highbd_obmc_variance_neon.c",
    "aom_dsp/arm/highbd_quantize_neon.c",             "aom_dsp/arm/highbd_sad_neon.c",                  "aom_dsp/arm/highbd_sadxd_neon.c",
    "aom_dsp/arm/highbd_sse_neon.c",                  "aom_dsp/arm/highbd_subpel_variance_neon.c",      "aom_dsp/arm/highbd_variance_neon.c",
    "aom_dsp/arm/intrapred_neon.c",                   "aom_dsp/arm/loopfilter_neon.c",                  "aom_dsp/arm/masked_sad_neon.c",
    "aom_dsp/arm/obmc_sad_neon.c",                    "aom_dsp/arm/obmc_variance_neon.c",               "aom_dsp/arm/sad_neon.c",
    "aom_dsp/arm/sadxd_neon.c",                       "aom_dsp/arm/sse_neon.c",                         "aom_dsp/arm/subpel_variance_neon.c",
    "aom_dsp/arm/subtract_neon.c",                    "aom_dsp/arm/sum_squares_neon.c",                 "aom_dsp/arm/variance_neon.c",
    "aom_dsp/flow_estimation/arm/disflow_neon.c",     "aom_ports/aarch64_cpudetect.c",                  "av1/common/arm/av1_convolve_horiz_rs_neon.c",
    "av1/common/arm/av1_convolve_scale_neon.c",       "av1/common/arm/av1_inv_txfm_neon.c",             "av1/common/arm/av1_txfm_neon.c",
    "av1/common/arm/blend_a64_hmask_neon.c",          "av1/common/arm/blend_a64_vmask_neon.c",          "av1/common/arm/cdef_block_neon.c",
    "av1/common/arm/cfl_neon.c",                      "av1/common/arm/compound_convolve_neon.c",        "av1/common/arm/convolve_neon.c",
    "av1/common/arm/highbd_compound_convolve_neon.c", "av1/common/arm/highbd_convolve_horiz_rs_neon.c", "av1/common/arm/highbd_convolve_neon.c",
    "av1/common/arm/highbd_convolve_scale_neon.c",    "av1/common/arm/highbd_inv_txfm_neon.c",          "av1/common/arm/highbd_reconinter_neon.c",
    "av1/common/arm/highbd_reconintra_neon.c",        "av1/common/arm/highbd_warp_plane_neon.c",        "av1/common/arm/highbd_wiener_convolve_neon.c",
    "av1/common/arm/reconinter_neon.c",               "av1/common/arm/reconintra_neon.c",               "av1/common/arm/resize_neon.c",
    "av1/common/arm/selfguided_neon.c",               "av1/common/arm/warp_plane_neon.c",               "av1/common/arm/wiener_convolve_neon.c",
    "av1/encoder/arm/av1_error_neon.c",               "av1/encoder/arm/av1_fwd_txfm2d_neon.c",          "av1/encoder/arm/av1_highbd_quantize_neon.c",
    "av1/encoder/arm/av1_k_means_neon.c",             "av1/encoder/arm/cnn_neon.c",                     "av1/encoder/arm/encodetxb_neon.c",
    "av1/encoder/arm/highbd_fwd_txfm_neon.c",         "av1/encoder/arm/highbd_pickrst_neon.c",          "av1/encoder/arm/highbd_rdopt_neon.c",
    "av1/encoder/arm/highbd_temporal_filter_neon.c",  "av1/encoder/arm/hybrid_fwd_txfm_neon.c",         "av1/encoder/arm/ml_neon.c",
    "av1/encoder/arm/pickrst_neon.c",                 "av1/encoder/arm/quantize_neon.c",                "av1/encoder/arm/rdopt_neon.c",
    "av1/encoder/arm/reconinter_enc_neon.c",          "av1/encoder/arm/temporal_filter_neon.c",         "av1/encoder/arm/wedge_utils_neon.c",
};

const dotprod_files = [_][]const u8{
    "aom_dsp/arm/aom_convolve8_neon_dotprod.c",         "aom_dsp/arm/aom_scaled_convolve8_neon_dotprod.c", "aom_dsp/arm/highbd_variance_neon_dotprod.c",
    "aom_dsp/arm/sad_neon_dotprod.c",                   "aom_dsp/arm/sadxd_neon_dotprod.c",                "aom_dsp/arm/sse_neon_dotprod.c",
    "aom_dsp/arm/subpel_variance_neon_dotprod.c",       "aom_dsp/arm/sum_squares_neon_dotprod.c",          "aom_dsp/arm/variance_neon_dotprod.c",
    "av1/common/arm/av1_convolve_scale_neon_dotprod.c", "av1/common/arm/compound_convolve_neon_dotprod.c", "av1/common/arm/convolve_neon_dotprod.c",
    "av1/common/arm/resize_neon_dotprod.c",             "av1/encoder/arm/temporal_filter_neon_dotprod.c",
};

const i8mm_files = [_][]const u8{
    "aom_dsp/arm/aom_convolve8_neon_i8mm.c",        "aom_dsp/arm/aom_scaled_convolve8_neon_i8mm.c", "av1/common/arm/av1_convolve_scale_neon_i8mm.c",
    "av1/common/arm/compound_convolve_neon_i8mm.c", "av1/common/arm/convolve_neon_i8mm.c",          "av1/common/arm/resize_neon_i8mm.c",
    "av1/common/arm/warp_plane_neon_i8mm.c",        "av1/common/arm/reconintra_neon_i8mm.c",
};

const sve_files = [_][]const u8{
    "aom_dsp/arm/avg_sve.c",                     "aom_dsp/arm/blk_sse_sum_sve.c",          "aom_dsp/arm/highbd_convolve8_sve.c",
    "aom_dsp/arm/highbd_sse_sve.c",              "aom_dsp/arm/highbd_variance_sve.c",      "aom_dsp/arm/sum_squares_sve.c",
    "aom_dsp/flow_estimation/arm/disflow_sve.c", "av1/common/arm/highbd_warp_plane_sve.c", "av1/common/arm/warp_plane_sve.c",
    "av1/encoder/arm/av1_error_sve.c",           "av1/encoder/arm/highbd_pickrst_sve.c",   "av1/encoder/arm/pickrst_sve.c",
    "av1/encoder/arm/wedge_utils_sve.c",
};

const sve2_files = [_][]const u8{
    "av1/common/arm/convolve_sve2.c", "av1/common/arm/highbd_compound_convolve_sve2.c", "av1/common/arm/highbd_convolve_sve2.c",
};

const crc_files = [_][]const u8{
    "av1/encoder/arm/hash_arm_crc32.c",
};
