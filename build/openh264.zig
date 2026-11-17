const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

const Component = struct {
    dir: []const u8,
    includes: []const []const u8,
    cpp: []const []const u8,
    x86_asm: []const []const u8,
    arm64_asm: []const []const u8,
};

pub fn build(c: Ctx, nasm: Nasm) *std.Build.Step.Compile {
    const b = c.b;
    const t = c.target.result;
    const src = c.upstream("openh264");
    const x86 = t.cpu.arch.isX86();
    const x86_64 = t.cpu.arch == .x86_64;
    const arm64 = t.cpu.arch == .aarch64;
    const darwin = t.os.tag.isDarwin();
    const windows = c.isWindows();
    // C callers reach the asm through a leading underscore on these ABIs.
    const prefix = darwin or (windows and t.cpu.arch == .x86);

    const generated = b.addWriteFiles();
    _ = generated.add("version_gen.h",
        \\#ifndef VERSION_GEN_H
        \\#define VERSION_GEN_H
        \\#define VERSION_NUMBER ""
        \\#endif
        \\
    );

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{ "-DNDEBUG", "-DGENERATED_VERSION_HEADER", "-fno-strict-aliasing", "-fstack-protector-all" }) catch @panic("OOM");
    if (x86) flags.appendSlice(b.allocator, &.{ "-DX86_ASM", "-DHAVE_AVX2" }) catch @panic("OOM");
    if (t.cpu.arch == .x86) flags.append(b.allocator, "-DX86_32_ASM") catch @panic("OOM");
    if (arm64) flags.append(b.allocator, "-DHAVE_NEON_AARCH64") catch @panic("OOM");

    var asm_flags: std.ArrayList([]const u8) = .empty;
    asm_flags.appendSlice(b.allocator, &.{ if (x86_64) (if (windows) "-DWIN64" else "-DUNIX64") else "-DX86_32", "-DHAVE_AVX2" }) catch @panic("OOM");
    if (prefix) asm_flags.append(b.allocator, "-DPREFIX") catch @panic("OOM");

    const mod = c.module(.{ .cpp = true });
    for (components) |comp| {
        c.addSources(mod, b.fmt("openh264_{s}", .{std.fs.path.basename(comp.dir)}), .{
            .module = .{ .cpp = true },
            .setup = setup(c, src, generated, comp.includes, arm64),
            .groups = &.{
                .{ .root = src.path(comp.dir), .files = comp.cpp, .flags = flags.items },
                .{ .root = src.path(comp.dir), .files = if (arm64) comp.arm64_asm else &.{}, .flags = flags.items },
            },
        });
        if (x86) {
            nasm.addFiles(c, mod, .{
                .root = src.path(comp.dir),
                .files = comp.x86_asm,
                .include_dirs = &.{src.path("codec/common/x86")},
                .flags = asm_flags.items,
            });
        }
    }

    const lib = c.staticLibrary("openh264", mod);
    for ([_][]const u8{ "codec_api.h", "codec_app_def.h", "codec_def.h", "codec_ver.h" }) |h| {
        lib.installHeader(src.path(b.fmt("codec/api/wels/{s}", .{h})), b.fmt("wels/{s}", .{h}));
    }
    return lib;
}

fn setup(c: Ctx, src: *std.Build.Dependency, generated: *std.Build.Step.WriteFile, includes: []const []const u8, arm64: bool) Ctx.Setup {
    var out: std.ArrayList(std.Build.LazyPath) = .empty;
    out.appendSlice(c.b.allocator, &.{ generated.getDirectory(), src.path("codec/api/wels"), src.path("codec/common/inc") }) catch @panic("OOM");
    out.appendSlice(c.b.allocator, c.includeDirs(src.path(""), includes)) catch @panic("OOM");
    if (arm64) out.append(c.b.allocator, src.path("codec/common/arm64")) catch @panic("OOM");
    return .{ .includes = out.items };
}

const components = [_]Component{
    .{
        .dir = "codec/common",
        .includes = &.{},
        .cpp = &.{
            "src/common_tables.cpp",     "src/copy_mb.cpp",    "src/cpu.cpp",               "src/crt_util_safe_x.cpp",
            "src/deblocking_common.cpp", "src/expand_pic.cpp", "src/intra_pred_common.cpp", "src/mc.cpp",
            "src/memory_align.cpp",      "src/sad_common.cpp", "src/utils.cpp",             "src/welsCodecTrace.cpp",
            "src/WelsTaskThread.cpp",    "src/WelsThread.cpp", "src/WelsThreadLib.cpp",     "src/WelsThreadPool.cpp",
        },
        .x86_asm = &.{
            "x86/cpuid.asm",   "x86/dct.asm",       "x86/deblock.asm", "x86/expand_picture.asm", "x86/intra_pred_com.asm",
            "x86/mb_copy.asm", "x86/mc_chroma.asm", "x86/mc_luma.asm", "x86/satd_sad.asm",       "x86/vaa.asm",
        },
        .arm64_asm = &.{
            "arm64/copy_mb_aarch64_neon.S",           "arm64/deblocking_aarch64_neon.S", "arm64/expand_picture_aarch64_neon.S",
            "arm64/intra_pred_common_aarch64_neon.S", "arm64/mc_aarch64_neon.S",
        },
    },
    .{
        .dir = "codec/encoder",
        .includes = &.{ "codec/encoder/core/inc", "codec/encoder/plus/inc", "codec/processing/interface" },
        .cpp = &.{
            "core/src/au_set.cpp",                "core/src/deblocking.cpp",           "core/src/decode_mb_aux.cpp",
            "core/src/encode_mb_aux.cpp",         "core/src/encoder.cpp",              "core/src/encoder_data_tables.cpp",
            "core/src/encoder_ext.cpp",           "core/src/get_intra_predictor.cpp",  "core/src/md.cpp",
            "core/src/mv_pred.cpp",               "core/src/nal_encap.cpp",            "core/src/paraset_strategy.cpp",
            "core/src/picture_handle.cpp",        "core/src/ratectl.cpp",              "core/src/ref_list_mgr_svc.cpp",
            "core/src/sample.cpp",                "core/src/set_mb_syn_cabac.cpp",     "core/src/set_mb_syn_cavlc.cpp",
            "core/src/slice_multi_threading.cpp", "core/src/svc_base_layer_md.cpp",    "core/src/svc_enc_slice_segment.cpp",
            "core/src/svc_encode_mb.cpp",         "core/src/svc_encode_slice.cpp",     "core/src/svc_mode_decision.cpp",
            "core/src/svc_motion_estimate.cpp",   "core/src/svc_set_mb_syn_cabac.cpp", "core/src/svc_set_mb_syn_cavlc.cpp",
            "core/src/wels_preprocess.cpp",       "core/src/wels_task_base.cpp",       "core/src/wels_task_encoder.cpp",
            "core/src/wels_task_management.cpp",  "plus/src/welsEncoderExt.cpp",
        },
        .x86_asm = &.{
            "core/x86/coeff.asm",   "core/x86/dct.asm",   "core/x86/intra_pred.asm", "core/x86/matrix_transpose.asm",
            "core/x86/memzero.asm", "core/x86/quant.asm", "core/x86/sample_sc.asm",  "core/x86/score.asm",
        },
        .arm64_asm = &.{
            "core/arm64/intra_pred_aarch64_neon.S", "core/arm64/intra_pred_sad_3_opt_aarch64_neon.S", "core/arm64/memory_aarch64_neon.S",
            "core/arm64/pixel_aarch64_neon.S",      "core/arm64/reconstruct_aarch64_neon.S",          "core/arm64/svc_motion_estimation_aarch64_neon.S",
        },
    },
    .{
        .dir = "codec/decoder",
        .includes = &.{ "codec/decoder/core/inc", "codec/decoder/plus/inc" },
        .cpp = &.{
            "core/src/au_parser.cpp",          "core/src/bit_stream.cpp",          "core/src/cabac_decoder.cpp",
            "core/src/deblocking.cpp",         "core/src/decode_mb_aux.cpp",       "core/src/decode_slice.cpp",
            "core/src/decoder.cpp",            "core/src/decoder_core.cpp",        "core/src/decoder_data_tables.cpp",
            "core/src/error_concealment.cpp",  "core/src/fmo.cpp",                 "core/src/get_intra_predictor.cpp",
            "core/src/manage_dec_ref.cpp",     "core/src/memmgr_nal_unit.cpp",     "core/src/mv_pred.cpp",
            "core/src/parse_mb_syn_cabac.cpp", "core/src/parse_mb_syn_cavlc.cpp",  "core/src/pic_queue.cpp",
            "core/src/rec_mb.cpp",             "core/src/wels_decoder_thread.cpp", "plus/src/welsDecoderExt.cpp",
        },
        .x86_asm = &.{ "core/x86/dct.asm", "core/x86/intra_pred.asm" },
        .arm64_asm = &.{ "core/arm64/block_add_aarch64_neon.S", "core/arm64/intra_pred_aarch64_neon.S" },
    },
    .{
        .dir = "codec/processing",
        .includes = &.{
            "codec/processing/interface",      "codec/processing/src/common",          "codec/processing/src/adaptivequantization",
            "codec/processing/src/downsample", "codec/processing/src/scrolldetection", "codec/processing/src/vaacalc",
        },
        .cpp = &.{
            "src/adaptivequantization/AdaptiveQuantization.cpp", "src/backgrounddetection/BackgroundDetection.cpp",
            "src/common/memory.cpp",                             "src/common/WelsFrameWork.cpp",
            "src/common/WelsFrameWorkEx.cpp",                    "src/complexityanalysis/ComplexityAnalysis.cpp",
            "src/denoise/denoise.cpp",                           "src/denoise/denoise_filter.cpp",
            "src/downsample/downsample.cpp",                     "src/downsample/downsamplefuncs.cpp",
            "src/imagerotate/imagerotate.cpp",                   "src/imagerotate/imagerotatefuncs.cpp",
            "src/scenechangedetection/SceneChangeDetection.cpp", "src/scrolldetection/ScrollDetection.cpp",
            "src/scrolldetection/ScrollDetectionFuncs.cpp",      "src/vaacalc/vaacalcfuncs.cpp",
            "src/vaacalc/vaacalculation.cpp",
        },
        .x86_asm = &.{ "src/x86/denoisefilter.asm", "src/x86/downsample_bilinear.asm", "src/x86/vaa.asm" },
        .arm64_asm = &.{
            "src/arm64/adaptive_quantization_aarch64_neon.S", "src/arm64/down_sample_aarch64_neon.S",
            "src/arm64/pixel_sad_aarch64_neon.S",             "src/arm64/vaa_calc_aarch64_neon.S",
        },
    },
};
