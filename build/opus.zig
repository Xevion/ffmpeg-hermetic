const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "opus",
    .version = "1.6.1",
    .licenses = &.{"COPYING"},
    .ffmpeg = &.{"libopus"},
    .ffmpeg_include_subdirs = &.{"opus"},
    .system_libs = .{ .linux = &.{"m"} },
};

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const b = c.b;
    const src = c.upstream("opus");
    const mod = c.module(.{});
    const x86 = c.arch() == .x86_64;
    const arm64 = c.arch() == .aarch64 and !c.isWindows();

    const config = b.addConfigHeader(.{ .include_path = "config.h" }, .{
        .OPUS_BUILD = true,
        .VAR_ARRAYS = 1,
        .HAVE_LRINT = true,
        .HAVE_LRINTF = true,
        .HAVE_STDINT_H = true,
        .ENABLE_HARDENING = 1,
        .DISABLE_DEBUG_FLOAT = 1,
        .CPU_INFO_BY_ASM = if (x86) @as(?i64, 1) else null,
        .OPUS_HAVE_RTCD = if (x86 or arm64) @as(?i64, 1) else null,
        .OPUS_ARM_MAY_HAVE_NEON_INTR = if (arm64) @as(?i64, 1) else null,
        .OPUS_ARM_MAY_HAVE_DOTPROD = if (arm64) @as(?i64, 1) else null,
        .OPUS_ARM_PRESUME_NEON_INTR = if (arm64) @as(?i64, 1) else null,
        .OPUS_ARM_PRESUME_AARCH64_NEON_INTR = if (arm64) @as(?i64, 1) else null,
        .OPUS_X86_MAY_HAVE_SSE = if (x86) @as(?i64, 1) else null,
        .OPUS_X86_MAY_HAVE_SSE2 = if (x86) @as(?i64, 1) else null,
        .OPUS_X86_MAY_HAVE_SSE4_1 = if (x86) @as(?i64, 1) else null,
        .OPUS_X86_MAY_HAVE_AVX2 = if (x86) @as(?i64, 1) else null,
        .OPUS_X86_PRESUME_SSE = if (x86) @as(?i64, 1) else null,
        .OPUS_X86_PRESUME_SSE2 = if (x86) @as(?i64, 1) else null,
        .PACKAGE_VERSION = meta.version,
    });
    const base = [_][]const u8{ "-DHAVE_CONFIG_H", "-D_FILE_OFFSET_BITS=64", "-fvisibility=hidden" };
    const setup: Ctx.Setup = .{
        .config_headers = &.{config},
        .includes = c.includeDirs(src.path(""), &.{ "", "include", "celt", "silk", "silk/float", "silk/fixed", "dnn", "src" }),
    };

    setup.apply(mod);
    mod.addCSourceFiles(.{ .root = src.path(""), .files = &(silk ++ silk_float ++ celt ++ opus), .flags = &base });
    if (x86) {
        mod.addCSourceFiles(.{ .root = src.path(""), .files = &x86_base, .flags = &base });
        c.addSources(mod, "opus_sse4_1", .{
            .module = .{ .x86_features = &.{.sse4_1} },
            .setup = setup,
            .groups = &.{.{ .root = src.path(""), .files = &x86_sse4_1, .flags = &base }},
        });
        c.addSources(mod, "opus_avx2", .{
            .module = .{ .x86_features = &.{ .avx, .avx2, .fma } },
            .setup = setup,
            .groups = &.{.{ .root = src.path(""), .files = &x86_avx2, .flags = &base }},
        });
    }

    if (arm64) mod.addCSourceFiles(.{ .root = src.path(""), .files = &arm64_sources, .flags = &base });

    const lib = c.staticLibrary("opus", mod);
    lib.installHeadersDirectory(src.path("include"), "opus", .{});
    return c.single(lib);
}

const silk = [_][]const u8{
    "silk/A2NLSF.c",                   "silk/CNG.c",                       "silk/HP_variable_cutoff.c",
    "silk/LPC_analysis_filter.c",      "silk/LPC_fit.c",                   "silk/LPC_inv_pred_gain.c",
    "silk/LP_variable_cutoff.c",       "silk/NLSF2A.c",                    "silk/NLSF_VQ.c",
    "silk/NLSF_VQ_weights_laroia.c",   "silk/NLSF_decode.c",               "silk/NLSF_del_dec_quant.c",
    "silk/NLSF_encode.c",              "silk/NLSF_stabilize.c",            "silk/NLSF_unpack.c",
    "silk/NSQ.c",                      "silk/NSQ_del_dec.c",               "silk/PLC.c",
    "silk/VAD.c",                      "silk/VQ_WMat_EC.c",                "silk/ana_filt_bank_1.c",
    "silk/biquad_alt.c",               "silk/bwexpander.c",                "silk/bwexpander_32.c",
    "silk/check_control_input.c",      "silk/code_signs.c",                "silk/control_SNR.c",
    "silk/control_audio_bandwidth.c",  "silk/control_codec.c",             "silk/debug.c",
    "silk/dec_API.c",                  "silk/decode_core.c",               "silk/decode_frame.c",
    "silk/decode_indices.c",           "silk/decode_parameters.c",         "silk/decode_pitch.c",
    "silk/decode_pulses.c",            "silk/decoder_set_fs.c",            "silk/enc_API.c",
    "silk/encode_indices.c",           "silk/encode_pulses.c",             "silk/gain_quant.c",
    "silk/init_decoder.c",             "silk/init_encoder.c",              "silk/inner_prod_aligned.c",
    "silk/interpolate.c",              "silk/lin2log.c",                   "silk/log2lin.c",
    "silk/pitch_est_tables.c",         "silk/process_NLSFs.c",             "silk/quant_LTP_gains.c",
    "silk/resampler.c",                "silk/resampler_down2.c",           "silk/resampler_down2_3.c",
    "silk/resampler_private_AR2.c",    "silk/resampler_private_IIR_FIR.c", "silk/resampler_private_down_FIR.c",
    "silk/resampler_private_up2_HQ.c", "silk/resampler_rom.c",             "silk/shell_coder.c",
    "silk/sigm_Q15.c",                 "silk/sort.c",                      "silk/stereo_LR_to_MS.c",
    "silk/stereo_MS_to_LR.c",          "silk/stereo_decode_pred.c",        "silk/stereo_encode_pred.c",
    "silk/stereo_find_predictor.c",    "silk/stereo_quant_pred.c",         "silk/sum_sqr_shift.c",
    "silk/table_LSF_cos.c",            "silk/tables_LTP.c",                "silk/tables_NLSF_CB_NB_MB.c",
    "silk/tables_NLSF_CB_WB.c",        "silk/tables_gain.c",               "silk/tables_other.c",
    "silk/tables_pitch_lag.c",         "silk/tables_pulses_per_block.c",
};

const silk_float = [_][]const u8{
    "silk/float/LPC_analysis_filter_FLP.c", "silk/float/LPC_inv_pred_gain_FLP.c", "silk/float/LTP_analysis_filter_FLP.c",
    "silk/float/LTP_scale_ctrl_FLP.c",      "silk/float/apply_sine_window_FLP.c", "silk/float/autocorrelation_FLP.c",
    "silk/float/burg_modified_FLP.c",       "silk/float/bwexpander_FLP.c",        "silk/float/corrMatrix_FLP.c",
    "silk/float/encode_frame_FLP.c",        "silk/float/energy_FLP.c",            "silk/float/find_LPC_FLP.c",
    "silk/float/find_LTP_FLP.c",            "silk/float/find_pitch_lags_FLP.c",   "silk/float/find_pred_coefs_FLP.c",
    "silk/float/inner_product_FLP.c",       "silk/float/k2a_FLP.c",               "silk/float/noise_shape_analysis_FLP.c",
    "silk/float/pitch_analysis_core_FLP.c", "silk/float/process_gains_FLP.c",     "silk/float/regularize_correlations_FLP.c",
    "silk/float/residual_energy_FLP.c",     "silk/float/scale_copy_vector_FLP.c", "silk/float/scale_vector_FLP.c",
    "silk/float/schur_FLP.c",               "silk/float/sort_FLP.c",              "silk/float/warped_autocorrelation_FLP.c",
    "silk/float/wrappers_FLP.c",
};

const celt = [_][]const u8{
    "celt/bands.c",       "celt/celt.c",    "celt/celt_decoder.c", "celt/celt_encoder.c", "celt/celt_lpc.c",
    "celt/cwrs.c",        "celt/entcode.c", "celt/entdec.c",       "celt/entenc.c",       "celt/kiss_fft.c",
    "celt/laplace.c",     "celt/mathops.c", "celt/mdct.c",         "celt/modes.c",        "celt/pitch.c",
    "celt/quant_bands.c", "celt/rate.c",    "celt/vq.c",
};

const opus = [_][]const u8{
    "src/analysis.c",                 "src/extensions.c",               "src/mapping_matrix.c",
    "src/mlp.c",                      "src/mlp_data.c",                 "src/opus.c",
    "src/opus_decoder.c",             "src/opus_encoder.c",             "src/opus_multistream.c",
    "src/opus_multistream_decoder.c", "src/opus_multistream_encoder.c", "src/opus_projection_decoder.c",
    "src/opus_projection_encoder.c",  "src/repacketizer.c",
};

const x86_base = [_][]const u8{
    "silk/x86/x86_silk_map.c", "celt/x86/x86_celt_map.c", "celt/x86/x86cpu.c",
    "celt/x86/pitch_sse.c",    "celt/x86/pitch_sse2.c",   "celt/x86/vq_sse2.c",
    "dnn/x86/nnet_sse2.c",
};

const x86_sse4_1 = [_][]const u8{
    "silk/x86/NSQ_del_dec_sse4_1.c", "silk/x86/NSQ_sse4_1.c",      "silk/x86/VAD_sse4_1.c",
    "silk/x86/VQ_WMat_EC_sse4_1.c",  "celt/x86/celt_lpc_sse4_1.c", "celt/x86/pitch_sse4_1.c",
    "dnn/x86/nnet_sse4_1.c",
};

const x86_avx2 = [_][]const u8{
    "silk/float/x86/inner_product_FLP_avx2.c", "silk/x86/NSQ_del_dec_avx2.c", "celt/x86/pitch_avx.c",
    "dnn/x86/nnet_avx2.c",
};

const arm64_sources = [_][]const u8{
    "celt/arm/armcpu.c",                      "celt/arm/arm_celt_map.c",          "celt/arm/celt_neon_intr.c",
    "celt/arm/pitch_neon_intr.c",             "silk/arm/arm_silk_map.c",          "silk/arm/biquad_alt_neon_intr.c",
    "silk/arm/LPC_inv_pred_gain_neon_intr.c", "silk/arm/NSQ_del_dec_neon_intr.c", "silk/arm/NSQ_neon.c",
};
