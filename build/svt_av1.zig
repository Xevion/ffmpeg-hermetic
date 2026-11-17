const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

const version = "v3.1.2";

pub fn build(c: Ctx, nasm: Nasm) *std.Build.Step.Compile {
    const b = c.b;
    const src = c.upstream("svt_av1");
    const x86_64 = c.arch() == .x86_64;
    const windows = c.isWindows();
    const arm64 = c.arch() == .aarch64 and !windows;

    const generated = b.addWriteFiles();
    _ = generated.add("EbVersion.h", "#define SVT_AV1_CVS_VERSION \"" ++ version ++ "\"\n");

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{
        "-DNDEBUG",
        "-DEXCLUDE_HASH=0",
        "-DREPRODUCIBLE_BUILDS=1",
        "-DSAFECLIB_STR_NULL_SLACK=1",
        "-DHAVE_BUILTIN_EXPECT=1",
        "-DHAVE_ELF_AUX_INFO=0",
        "-DHAVE_VALGRIND_H=0",
        "-fvisibility=hidden",
    }) catch @panic("OOM");
    if (x86_64) flags.appendSlice(b.allocator, &.{ "-DARCH_X86_64=1", "-DEN_AVX512_SUPPORT=1" }) catch @panic("OOM");
    if (arm64) flags.appendSlice(b.allocator, &.{
        "-DARCH_AARCH64=1",
        "-DHAVE_NEON=1",
        "-DHAVE_ARM_CRC32=1",
        "-DHAVE_NEON_DOTPROD=1",
        "-DHAVE_NEON_I8MM=1",
        "-DHAVE_SVE=1",
        "-DHAVE_SVE2=1",
        "-fno-lax-vector-conversions",
        // Keeps aarch64 bitstreams identical to x86's.
        "-ffp-contract=off",
    }) catch @panic("OOM");
    if (windows) flags.append(b.allocator, "-D_WIN32_WINNT=0x0601") catch @panic("OOM");

    const setup: Ctx.Setup = .{ .includes = std.mem.concat(b.allocator, std.Build.LazyPath, &.{
        &.{generated.getDirectory()},
        c.includeDirs(src.path(""), &.{
            "",
            "Source/API",
            "Source/Lib/Globals",
            "Source/Lib/Codec",
            "Source/Lib/C_DEFAULT",
            "Source/Lib/ASM_SSE2",
            "Source/Lib/ASM_SSSE3",
            "Source/Lib/ASM_SSE4_1",
            "Source/Lib/ASM_AVX2",
            "Source/Lib/ASM_AVX512",
            "Source/Lib/ASM_NEON",
            "Source/Lib/ASM_NEON_DOTPROD",
            "Source/Lib/ASM_NEON_I8MM",
            "Source/Lib/ASM_SVE",
            "Source/Lib/ASM_SVE2",
            "third_party/fastfeat",
        }),
    }) catch @panic("OOM") };

    const mod = c.module(.{});
    setup.apply(mod);
    for ([_][]const []const u8{ &base, &globals, &c_default, &fastfeat }) |files| {
        mod.addCSourceFiles(.{ .root = src.path(""), .files = files, .flags = flags.items });
    }
    if (!c.isMsvc()) mod.addCSourceFiles(.{ .root = src.path(""), .files = &safestring, .flags = flags.items });

    if (x86_64) {
        const F = std.Target.x86.Feature;
        const isas = [_]struct { name: []const u8, features: []const F, files: []const []const u8 }{
            .{ .name = "svt_av1_sse2", .features = &.{.sse2}, .files = &asm_sse2 },
            .{ .name = "svt_av1_ssse3", .features = &.{.ssse3}, .files = &asm_ssse3 },
            .{ .name = "svt_av1_sse4_1", .features = &.{.sse4_1}, .files = &asm_sse4_1 },
            .{ .name = "svt_av1_avx2", .features = &.{.avx2}, .files = &asm_avx2 },
            .{ .name = "svt_av1_avx512", .features = &.{ .avx2, .avx512f, .avx512bw, .avx512dq, .avx512vl }, .files = &asm_avx512 },
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
            .files = &nasm_files,
            .include_dirs = &.{
                src.path(""),
                src.path("Source/API"),
                src.path("Source/Lib/Codec"),
                src.path("Source/Lib/C_DEFAULT"),
                src.path("third_party/fastfeat"),
                src.path("Source/Lib/ASM_SSE2"),
                src.path("Source/Lib/ASM_SSSE3"),
                src.path("Source/Lib/ASM_SSE4_1"),
                src.path("Source/Lib/ASM_AVX2"),
                src.path("Source/Lib/ASM_AVX512"),
            },
            .flags = &.{ "-DARCH_X86_64=1", "-DEN_AVX512_SUPPORT=1", "-DEXCLUDE_HASH=0", "-DREPRODUCIBLE_BUILDS=1", if (windows) "-DWIN64" else "-DUNIX64" },
        });
    }

    if (arm64) {
        const Isa = struct { name: []const u8, features: []const std.Target.aarch64.Feature, files: []const []const u8 };
        const isas = [_]Isa{
            .{ .name = "svt_av1_neon", .features = &.{}, .files = &aarch64_neon },
            .{ .name = "svt_av1_neon_dotprod", .features = &.{.dotprod}, .files = &aarch64_dotprod },
            .{ .name = "svt_av1_neon_i8mm", .features = &.{ .dotprod, .i8mm }, .files = &aarch64_i8mm },
            .{ .name = "svt_av1_sve", .features = &.{ .dotprod, .i8mm, .sve }, .files = &aarch64_sve },
            .{ .name = "svt_av1_sve2", .features = &.{ .v9a, .i8mm, .sve2 }, .files = &aarch64_sve2 },
        };
        for (isas) |isa| {
            c.addSources(mod, isa.name, .{
                .module = .{ .aarch64_features = isa.features },
                .setup = setup,
                .groups = &.{.{ .root = src.path(""), .files = isa.files, .flags = flags.items }},
            });
        }
    }

    const lib = c.staticLibrary("SvtAv1Enc", mod);
    lib.installHeadersDirectory(src.path("Source/API"), "svt-av1", .{ .include_extensions = &.{".h"} });
    return lib;
}

const safestring = [_][]const u8{
    "third_party/safestringlib/ignore_handler_s.c",
    "third_party/safestringlib/safe_str_constraint.c",
    "third_party/safestringlib/strcpy_s.c",
    "third_party/safestringlib/strncpy_s.c",
    "third_party/safestringlib/strnlen_s.c",
};

const c_default = [_][]const u8{
    "Source/Lib/C_DEFAULT/blend_a64_mask_c.c",
    "Source/Lib/C_DEFAULT/cfl_c.c",
    "Source/Lib/C_DEFAULT/compute_sad_c.c",
    "Source/Lib/C_DEFAULT/encode_txb_ref_c.c",
    "Source/Lib/C_DEFAULT/filterintra_c.c",
    "Source/Lib/C_DEFAULT/inter_prediction_c.c",
    "Source/Lib/C_DEFAULT/intra_prediction_c.c",
    "Source/Lib/C_DEFAULT/pack_unpack_c.c",
    "Source/Lib/C_DEFAULT/picture_operators_c.c",
    "Source/Lib/C_DEFAULT/sad_av1.c",
    "Source/Lib/C_DEFAULT/variance.c",
};

const base = [_][]const u8{
    "Source/Lib/Codec/adaptive_mv_pred.c",
    "Source/Lib/Codec/aom_dsp_rtcd.c",
    "Source/Lib/Codec/av1me.c",
    "Source/Lib/Codec/bitstream_unit.c",
    "Source/Lib/Codec/blend_a64_mask.c",
    "Source/Lib/Codec/block_structures.c",
    "Source/Lib/Codec/cabac_context_model.c",
    "Source/Lib/Codec/cdef.c",
    "Source/Lib/Codec/cdef_process.c",
    "Source/Lib/Codec/coding_loop.c",
    "Source/Lib/Codec/coding_unit.c",
    "Source/Lib/Codec/common_dsp_rtcd.c",
    "Source/Lib/Codec/convolve.c",
    "Source/Lib/Codec/corner_detect.c",
    "Source/Lib/Codec/corner_match.c",
    "Source/Lib/Codec/deblocking_common.c",
    "Source/Lib/Codec/deblocking_filter.c",
    "Source/Lib/Codec/dlf_process.c",
    "Source/Lib/Codec/dwt.c",
    "Source/Lib/Codec/ec_process.c",
    "Source/Lib/Codec/ec_results.c",
    "Source/Lib/Codec/enc_cdef.c",
    "Source/Lib/Codec/enc_dec_process.c",
    "Source/Lib/Codec/enc_dec_results.c",
    "Source/Lib/Codec/enc_dec_segments.c",
    "Source/Lib/Codec/enc_dec_tasks.c",
    "Source/Lib/Codec/enc_inter_prediction.c",
    "Source/Lib/Codec/enc_intra_prediction.c",
    "Source/Lib/Codec/enc_mode_config.c",
    "Source/Lib/Codec/enc_warped_motion.c",
    "Source/Lib/Codec/encode_context.c",
    "Source/Lib/Codec/entropy_coding.c",
    "Source/Lib/Codec/fft.c",
    "Source/Lib/Codec/firstpass.c",
    "Source/Lib/Codec/full_loop.c",
    "Source/Lib/Codec/global_me.c",
    "Source/Lib/Codec/global_me_cost.c",
    "Source/Lib/Codec/global_motion.c",
    "Source/Lib/Codec/grainSynthesis.c",
    "Source/Lib/Codec/hash.c",
    "Source/Lib/Codec/hash_motion.c",
    "Source/Lib/Codec/initial_rc_process.c",
    "Source/Lib/Codec/initial_rc_reorder_queue.c",
    "Source/Lib/Codec/initial_rc_results.c",
    "Source/Lib/Codec/inter_prediction.c",
    "Source/Lib/Codec/intra_prediction.c",
    "Source/Lib/Codec/inv_transforms.c",
    "Source/Lib/Codec/mcomp.c",
    "Source/Lib/Codec/md_config_process.c",
    "Source/Lib/Codec/md_process.c",
    "Source/Lib/Codec/md_rate_estimation.c",
    "Source/Lib/Codec/me_context.c",
    "Source/Lib/Codec/me_process.c",
    "Source/Lib/Codec/me_results.c",
    "Source/Lib/Codec/me_sad_calculation.c",
    "Source/Lib/Codec/mode_decision.c",
    "Source/Lib/Codec/motion_estimation.c",
    "Source/Lib/Codec/neighbor_arrays.c",
    "Source/Lib/Codec/noise_model.c",
    "Source/Lib/Codec/noise_util.c",
    "Source/Lib/Codec/packetization_process.c",
    "Source/Lib/Codec/packetization_reorder_queue.c",
    "Source/Lib/Codec/palette.c",
    "Source/Lib/Codec/pass2_strategy.c",
    "Source/Lib/Codec/pcs.c",
    "Source/Lib/Codec/pd_process.c",
    "Source/Lib/Codec/pd_queue.c",
    "Source/Lib/Codec/pd_reorder_queue.c",
    "Source/Lib/Codec/pd_results.c",
    "Source/Lib/Codec/pic_analysis_process.c",
    "Source/Lib/Codec/pic_analysis_results.c",
    "Source/Lib/Codec/pic_buffer_desc.c",
    "Source/Lib/Codec/pic_demux_results.c",
    "Source/Lib/Codec/pic_manager_process.c",
    "Source/Lib/Codec/pic_manager_queue.c",
    "Source/Lib/Codec/pic_operators.c",
    "Source/Lib/Codec/pred_structure.c",
    "Source/Lib/Codec/product_coding_loop.c",
    "Source/Lib/Codec/ransac.c",
    "Source/Lib/Codec/rc_process.c",
    "Source/Lib/Codec/rc_results.c",
    "Source/Lib/Codec/rc_tasks.c",
    "Source/Lib/Codec/rd_cost.c",
    "Source/Lib/Codec/reference_object.c",
    "Source/Lib/Codec/resize.c",
    "Source/Lib/Codec/resource_coordination_process.c",
    "Source/Lib/Codec/resource_coordination_results.c",
    "Source/Lib/Codec/rest_process.c",
    "Source/Lib/Codec/restoration.c",
    "Source/Lib/Codec/restoration_pick.c",
    "Source/Lib/Codec/segmentation.c",
    "Source/Lib/Codec/segmentation_params.c",
    "Source/Lib/Codec/sequence_control_set.c",
    "Source/Lib/Codec/src_ops_process.c",
    "Source/Lib/Codec/super_res.c",
    "Source/Lib/Codec/svt_log.c",
    "Source/Lib/Codec/svt_malloc.c",
    "Source/Lib/Codec/svt_psnr.c",
    "Source/Lib/Codec/svt_threads.c",
    "Source/Lib/Codec/svt_time.c",
    "Source/Lib/Codec/sys_resource_manager.c",
    "Source/Lib/Codec/temporal_filtering.c",
    "Source/Lib/Codec/transforms.c",
    "Source/Lib/Codec/utility.c",
    "Source/Lib/Codec/vector.c",
    "Source/Lib/Codec/warped_motion.c",
};

const globals = [_][]const u8{
    "Source/Lib/Globals/enc_handle.c",
    "Source/Lib/Globals/enc_settings.c",
    "Source/Lib/Globals/metadata_handle.c",
};

const asm_sse2 = [_][]const u8{
    "Source/Lib/ASM_SSE2/avc_style_mcp_intrin_sse.c",
    "Source/Lib/ASM_SSE2/compute_mean_intrin_sse2.c",
    "Source/Lib/ASM_SSE2/convolve_2d_sse2.c",
    "Source/Lib/ASM_SSE2/convolve_sse2.c",
    "Source/Lib/ASM_SSE2/dlf_intrin_sse2.c",
    "Source/Lib/ASM_SSE2/encodetxb_sse2.c",
    "Source/Lib/ASM_SSE2/fft_sse2.c",
    "Source/Lib/ASM_SSE2/highbd_intrapred_sse2.c",
    "Source/Lib/ASM_SSE2/highbd_subtract_sse2.c",
    "Source/Lib/ASM_SSE2/highbd_variance_sse2.c",
    "Source/Lib/ASM_SSE2/intra_pred_av1_intrin_sse2.c",
    "Source/Lib/ASM_SSE2/jnt_convolve_2d_sse2.c",
    "Source/Lib/ASM_SSE2/jnt_convolve_sse2.c",
    "Source/Lib/ASM_SSE2/me_sad_calc_intrin_sse2.c",
    "Source/Lib/ASM_SSE2/pack_unpack_intrin_sse2.c",
    "Source/Lib/ASM_SSE2/pic_operators_intrin_sse2.c",
    "Source/Lib/ASM_SSE2/variance_sse2.c",
    "Source/Lib/ASM_SSE2/wiener_convolve_sse2.c",
};

const nasm_files = [_][]const u8{
    "Source/Lib/ASM_AVX2/itx16_avx2.asm",
    "Source/Lib/ASM_AVX2/itx_avx2.asm",
    "Source/Lib/ASM_AVX2/mc16_avx2.asm",
    "Source/Lib/ASM_AVX2/mc_avx2.asm",
    "Source/Lib/ASM_SSE2/aom_subpixel_8t_sse2.asm",
    "Source/Lib/ASM_SSE2/highbd_intrapred_sse2_.asm",
    "Source/Lib/ASM_SSE2/highbd_variance_impl_sse2.asm",
    "Source/Lib/ASM_SSE2/intrapred_sse2.asm",
    "Source/Lib/ASM_SSE2/picture_operators_sse2.asm",
    "Source/Lib/ASM_SSE2/subpel_variance_sse2.asm",
    "Source/Lib/ASM_SSE2/subtract_sse2.asm",
    "Source/Lib/ASM_SSSE3/aom_subpixel_8t_ssse3.asm",
    "Source/Lib/ASM_SSSE3/aom_subpixel_bilinear_ssse3.asm",
    "Source/Lib/ASM_SSSE3/subpel_variance_ssse3.asm",
};

const asm_ssse3 = [_][]const u8{
    "Source/Lib/ASM_SSSE3/aom_subpixel_8t_intrin_ssse3.c",
    "Source/Lib/ASM_SSSE3/av1_inv_txfm_ssse3.c",
    "Source/Lib/ASM_SSSE3/highbd_convolve_2d_ssse3.c",
    "Source/Lib/ASM_SSSE3/highbd_convolve_ssse3.c",
    "Source/Lib/ASM_SSSE3/highbd_intrapred_intrin_ssse3.c",
    "Source/Lib/ASM_SSSE3/highbd_wiener_convolve_ssse3.c",
    "Source/Lib/ASM_SSSE3/intrapred_ssse3.c",
    "Source/Lib/ASM_SSSE3/jnt_convolve_ssse3.c",
    "Source/Lib/ASM_SSSE3/reconinter_ssse3.c",
    "Source/Lib/ASM_SSSE3/variance_impl_ssse3.c",
};

const asm_sse4_1 = [_][]const u8{
    "Source/Lib/ASM_SSE4_1/av1_convolve_scale_sse4.c",
    "Source/Lib/ASM_SSE4_1/av1_quantize_sse4_1.c",
    "Source/Lib/ASM_SSE4_1/blend_a64_mask_sse4.c",
    "Source/Lib/ASM_SSE4_1/cdef_block_sse4_1.c",
    "Source/Lib/ASM_SSE4_1/cdef_sse4.c",
    "Source/Lib/ASM_SSE4_1/compute_sad_intrin_sse4_1.c",
    "Source/Lib/ASM_SSE4_1/corner_match_sse4.c",
    "Source/Lib/ASM_SSE4_1/encodetxb_sse4.c",
    "Source/Lib/ASM_SSE4_1/filterintra_sse4.c",
    "Source/Lib/ASM_SSE4_1/highbd_convolve_2d_sse4.c",
    "Source/Lib/ASM_SSE4_1/highbd_fwd_txfm_sse4.c",
    "Source/Lib/ASM_SSE4_1/highbd_inv_txfm_sse4.c",
    "Source/Lib/ASM_SSE4_1/highbd_jnt_convolve_sse4.c",
    "Source/Lib/ASM_SSE4_1/intrapred_16bit_intrin_sse4_1.c",
    "Source/Lib/ASM_SSE4_1/obmc_variance_sse4.c",
    "Source/Lib/ASM_SSE4_1/pic_operators_intrin_sse4_1.c",
    "Source/Lib/ASM_SSE4_1/pickrst_sse4.c",
    "Source/Lib/ASM_SSE4_1/reconinter_sse4.c",
    "Source/Lib/ASM_SSE4_1/selfguided_sse4.c",
    "Source/Lib/ASM_SSE4_1/temporal_filtering_sse4_1.c",
    "Source/Lib/ASM_SSE4_1/warp_plane_sse4.c",
};

const asm_avx2 = [_][]const u8{
    "Source/Lib/ASM_AVX2/aom_subpixel_8t_intrin_avx2.c",
    "Source/Lib/ASM_AVX2/av1_inv_txfm_avx2.c",
    "Source/Lib/ASM_AVX2/av1_quantize_avx2.c",
    "Source/Lib/ASM_AVX2/blend_a64_mask_avx2.c",
    "Source/Lib/ASM_AVX2/cdef_avx2.c",
    "Source/Lib/ASM_AVX2/cdef_block_avx2.c",
    "Source/Lib/ASM_AVX2/cfl_avx2.c",
    "Source/Lib/ASM_AVX2/comb_avg_sad_intrin_avx2.c",
    "Source/Lib/ASM_AVX2/compute_sad_intrin_avx2.c",
    "Source/Lib/ASM_AVX2/convolve_2d_avx2.c",
    "Source/Lib/ASM_AVX2/convolve_avx2.c",
    "Source/Lib/ASM_AVX2/corner_match_avx2.c",
    "Source/Lib/ASM_AVX2/dwt_avx2.c",
    "Source/Lib/ASM_AVX2/encodetxb_avx2.c",
    "Source/Lib/ASM_AVX2/fft_avx2.c",
    "Source/Lib/ASM_AVX2/highbd_convolve_2d_avx2.c",
    "Source/Lib/ASM_AVX2/highbd_convolve_avx2.c",
    "Source/Lib/ASM_AVX2/highbd_fwd_txfm_avx2.c",
    "Source/Lib/ASM_AVX2/highbd_intra_pred_avx2.c",
    "Source/Lib/ASM_AVX2/highbd_inv_txfm_avx2.c",
    "Source/Lib/ASM_AVX2/highbd_jnt_convolve_avx2.c",
    "Source/Lib/ASM_AVX2/highbd_quantize_intrin_avx2.c",
    "Source/Lib/ASM_AVX2/highbd_variance_avx2.c",
    "Source/Lib/ASM_AVX2/highbd_warp_affine_avx2.c",
    "Source/Lib/ASM_AVX2/inter_prediction_com_avx2.c",
    "Source/Lib/ASM_AVX2/intra_pred_intrin_avx2.c",
    "Source/Lib/ASM_AVX2/jnt_convolve_2d_avx2.c",
    "Source/Lib/ASM_AVX2/jnt_convolve_avx2.c",
    "Source/Lib/ASM_AVX2/noise_model_avx2.c",
    "Source/Lib/ASM_AVX2/obmc_sad_avx2.c",
    "Source/Lib/ASM_AVX2/obmc_variance_avx2.c",
    "Source/Lib/ASM_AVX2/pack_unpack_intrinsic_avx2.c",
    "Source/Lib/ASM_AVX2/palette_avx2.c",
    "Source/Lib/ASM_AVX2/pic_operators_intrin_avx2.c",
    "Source/Lib/ASM_AVX2/pickrst_avx2.c",
    "Source/Lib/ASM_AVX2/resize_avx2.c",
    "Source/Lib/ASM_AVX2/restoration_pick_avx2.c",
    "Source/Lib/ASM_AVX2/selfguided_avx2.c",
    "Source/Lib/ASM_AVX2/sse_avx2.c",
    "Source/Lib/ASM_AVX2/ssim_avx2.c",
    "Source/Lib/ASM_AVX2/temporal_filtering_avx2.c",
    "Source/Lib/ASM_AVX2/transforms_intrin_avx2.c",
    "Source/Lib/ASM_AVX2/variance_avx2.c",
    "Source/Lib/ASM_AVX2/variance_impl_avx2.c",
    "Source/Lib/ASM_AVX2/warp_plane_avx2.c",
    "Source/Lib/ASM_AVX2/wiener_convolve_avx2.c",
};

const asm_avx512 = [_][]const u8{
    "Source/Lib/ASM_AVX512/cdef_avx512.c",
    "Source/Lib/ASM_AVX512/cdef_block_avx512.c",
    "Source/Lib/ASM_AVX512/compute_sad_intrin_avx512.c",
    "Source/Lib/ASM_AVX512/convolve_2d_avx512.c",
    "Source/Lib/ASM_AVX512/convolve_avx512.c",
    "Source/Lib/ASM_AVX512/encodetxb_avx512.c",
    "Source/Lib/ASM_AVX512/highbd_fwd_txfm_AVX512.c",
    "Source/Lib/ASM_AVX512/highbd_intra_pred_avx512.c",
    "Source/Lib/ASM_AVX512/highbd_inv_txfm_avx512.c",
    "Source/Lib/ASM_AVX512/jnt_convolve_2d_avx512.c",
    "Source/Lib/ASM_AVX512/jnt_convolve_avx512.c",
    "Source/Lib/ASM_AVX512/pic_operators_intrin_avx512.c",
    "Source/Lib/ASM_AVX512/pickrst_avx512.c",
    "Source/Lib/ASM_AVX512/variance_avx512.c",
    "Source/Lib/ASM_AVX512/wiener_convolve_avx512.c",
};

const fastfeat = [_][]const u8{
    "third_party/fastfeat/fast.c",
    "third_party/fastfeat/fast_9.c",
    "third_party/fastfeat/nonmax.c",
};

const aarch64_neon = [_][]const u8{
    "Source/Lib/ASM_NEON/aom_convolve8_neon.c",
    "Source/Lib/ASM_NEON/aom_sum_squares_neon.c",
    "Source/Lib/ASM_NEON/av1_inv_txfm_neon.c",
    "Source/Lib/ASM_NEON/av1_k_means_neon.c",
    "Source/Lib/ASM_NEON/av1_quantize_neon.c",
    "Source/Lib/ASM_NEON/blend_a64_mask_neon.c",
    "Source/Lib/ASM_NEON/block_error_neon.c",
    "Source/Lib/ASM_NEON/cdef_block_neon.c",
    "Source/Lib/ASM_NEON/cdef_filter_block_neon.c",
    "Source/Lib/ASM_NEON/cdef_neon.c",
    "Source/Lib/ASM_NEON/cfl_neon.c",
    "Source/Lib/ASM_NEON/compound_convolve_neon.c",
    "Source/Lib/ASM_NEON/compute_sad_neon.c",
    "Source/Lib/ASM_NEON/convolve_neon.c",
    "Source/Lib/ASM_NEON/convolve_scale_neon.c",
    "Source/Lib/ASM_NEON/corner_match_neon.c",
    "Source/Lib/ASM_NEON/dav1d_asm.S",
    "Source/Lib/ASM_NEON/dav1d_util.S",
    "Source/Lib/ASM_NEON/deblocking_filter_intrinsic_neon.c",
    "Source/Lib/ASM_NEON/encodetxb_neon.c",
    "Source/Lib/ASM_NEON/hadamard_path_neon.c",
    "Source/Lib/ASM_NEON/highbd_blend_a64_mask_neon.c",
    "Source/Lib/ASM_NEON/highbd_convolve_neon.c",
    "Source/Lib/ASM_NEON/highbd_convolve_scale_neon.c",
    "Source/Lib/ASM_NEON/highbd_fwd_txfm_neon.c",
    "Source/Lib/ASM_NEON/highbd_inter_prediction_neon.c",
    "Source/Lib/ASM_NEON/highbd_intra_prediction_neon.c",
    "Source/Lib/ASM_NEON/highbd_inv_txfm_neon.c",
    "Source/Lib/ASM_NEON/highbd_jnt_convolve_neon.c",
    "Source/Lib/ASM_NEON/highbd_loopfilter_neon.c",
    "Source/Lib/ASM_NEON/highbd_pickrst_neon.c",
    "Source/Lib/ASM_NEON/highbd_quantize_neon.c",
    "Source/Lib/ASM_NEON/highbd_sse_neon.c",
    "Source/Lib/ASM_NEON/highbd_subtract_block_neon.c",
    "Source/Lib/ASM_NEON/highbd_variance_neon.c",
    "Source/Lib/ASM_NEON/highbd_warp_plane_neon.c",
    "Source/Lib/ASM_NEON/highbd_wiener_convolve_neon.c",
    "Source/Lib/ASM_NEON/inter_prediction_neon.c",
    "Source/Lib/ASM_NEON/intra_prediction_neon.c",
    "Source/Lib/ASM_NEON/itx.S",
    "Source/Lib/ASM_NEON/obmc_sad_neon.c",
    "Source/Lib/ASM_NEON/obmc_variance_neon.c",
    "Source/Lib/ASM_NEON/pack_unpack_intrin_neon.c",
    "Source/Lib/ASM_NEON/pic_analysis_neon.c",
    "Source/Lib/ASM_NEON/pickrst_neon.c",
    "Source/Lib/ASM_NEON/picture_operators_intrinsic_neon.c",
    "Source/Lib/ASM_NEON/restoration_pick_neon.c",
    "Source/Lib/ASM_NEON/sad_neon.c",
    "Source/Lib/ASM_NEON/selfguided_neon.c",
    "Source/Lib/ASM_NEON/sse_neon.c",
    "Source/Lib/ASM_NEON/subtract_block_neon.c",
    "Source/Lib/ASM_NEON/temporal_filtering_neon.c",
    "Source/Lib/ASM_NEON/transforms_intrin_neon.c",
    "Source/Lib/ASM_NEON/upsampled_pred_neon.c",
    "Source/Lib/ASM_NEON/variance_neon.c",
    "Source/Lib/ASM_NEON/warp_plane_neon.c",
    "Source/Lib/ASM_NEON/wedge_utils_neon.c",
    "Source/Lib/ASM_NEON/wiener_convolve_neon.c",
};

const aarch64_dotprod = [_][]const u8{
    "Source/Lib/ASM_NEON_DOTPROD/aom_convolve8_neon_dotprod.c",
    "Source/Lib/ASM_NEON_DOTPROD/cdef_neon_dotprod.c",
    "Source/Lib/ASM_NEON_DOTPROD/compute_sad_neon_dotprod.c",
    "Source/Lib/ASM_NEON_DOTPROD/convolve_neon_dotprod.c",
    "Source/Lib/ASM_NEON_DOTPROD/convolve_scale_neon_dotprod.c",
    "Source/Lib/ASM_NEON_DOTPROD/corner_match_neon_dotprod.c",
    "Source/Lib/ASM_NEON_DOTPROD/highbd_variance_neon_dotprod.c",
    "Source/Lib/ASM_NEON_DOTPROD/jnt_convolve_neon_dotprod.c",
    "Source/Lib/ASM_NEON_DOTPROD/pic_analysis_neon_dotprod.c",
    "Source/Lib/ASM_NEON_DOTPROD/sad_neon_dotprod.c",
    "Source/Lib/ASM_NEON_DOTPROD/sse_neon_dotprod.c",
    "Source/Lib/ASM_NEON_DOTPROD/variance_neon_dotprod.c",
};

const aarch64_i8mm = [_][]const u8{
    "Source/Lib/ASM_NEON_I8MM/aom_convolve8_neon_i8mm.c",
    "Source/Lib/ASM_NEON_I8MM/convolve_neon_i8mm.c",
    "Source/Lib/ASM_NEON_I8MM/convolve_scale_neon_i8mm.c",
    "Source/Lib/ASM_NEON_I8MM/jnt_convolve_neon_i8mm.c",
    "Source/Lib/ASM_NEON_I8MM/warp_plane_neon_i8mm.c",
};

const aarch64_sve = [_][]const u8{
    "Source/Lib/ASM_SVE/aom_sum_squares_sve.c",
    "Source/Lib/ASM_SVE/block_error_sve.c",
    "Source/Lib/ASM_SVE/cdef_sve.c",
    "Source/Lib/ASM_SVE/compute_sad_sve.c",
    "Source/Lib/ASM_SVE/corner_match_sve.c",
    "Source/Lib/ASM_SVE/highbd_convolve_sve.c",
    "Source/Lib/ASM_SVE/highbd_jnt_convolve_sve.c",
    "Source/Lib/ASM_SVE/highbd_pickrst_sve.c",
    "Source/Lib/ASM_SVE/highbd_sse_sve.c",
    "Source/Lib/ASM_SVE/highbd_variance_sve.c",
    "Source/Lib/ASM_SVE/highbd_warp_plane_sve.c",
    "Source/Lib/ASM_SVE/pickrst_sve.c",
    "Source/Lib/ASM_SVE/sad_sve.c",
    "Source/Lib/ASM_SVE/warp_plane_sve.c",
    "Source/Lib/ASM_SVE/wedge_utils_sve.c",
};

const aarch64_sve2 = [_][]const u8{
    "Source/Lib/ASM_SVE2/highbd_convolve_sve2.c",
    "Source/Lib/ASM_SVE2/highbd_jnt_convolve_sve2.c",
};
