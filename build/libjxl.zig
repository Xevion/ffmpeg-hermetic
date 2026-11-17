const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");
const highway = @import("highway.zig");

pub const meta: Meta = .{
    .name = "libjxl",
    .version = "0.13.0",
    .licenses = &.{ "LICENSE", "PATENTS" },
    .extra_sources = &.{.{ .zon = "skcms", .version = "96d9171c", .licenses = &.{"LICENSE"} }},
    .needs = &.{ "highway", "brotli" },
    .ffmpeg = &.{"libjxl"},
    .ffmpeg_probes = &.{"libjxl_threads"},
    .system_libs = .{ .linux = &.{ "m", "pthread" } },
};

/// libjxl, libjxl_threads and libjxl_cms (skcms backend); libjxl carries every installed header.
/// Highway's targets and skcms's AVX2 and AVX-512 kernels are chosen at runtime.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const ver = Meta.versionParts(meta.version);
    const b = c.b;
    const src = c.upstream("libjxl");
    const skcms = c.upstream("skcms");
    const hwy_src = c.upstream("highway");
    const brotli_src = c.upstream("brotli");
    const x86 = c.arch() == .x86_64;

    const version = b.addConfigHeader(.{
        .style = .{ .cmake = src.path("lib/jxl/version.h.in") },
        .include_path = "jxl/version.h",
    }, .{ .JPEGXL_MAJOR_VERSION = ver[0], .JPEGXL_MINOR_VERSION = ver[1], .JPEGXL_PATCH_VERSION = ver[2] });
    const exports = b.addWriteFiles();
    _ = exports.add("jxl/jxl_export.h", exportHeader(b, "JXL", "JXL_STATIC_DEFINE", "__attribute__((visibility(\"default\")))", "__attribute__((visibility(\"hidden\")))"));
    _ = exports.add("jxl/jxl_cms_export.h", exportHeader(b, "JXL_CMS", "JXL_CMS_STATIC_DEFINE", "", ""));
    _ = exports.add("jxl/jxl_threads_export.h", exportHeader(b, "JXL_THREADS", "JXL_THREADS_STATIC_DEFINE", "", ""));

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{
        "-std=c++17",                  "-fno-rtti",                "-fvisibility=hidden",
        "-fvisibility-inlines-hidden", highway.disabledTargets(c), "-DFJXL_ENABLE_AVX512=0",
        "-funwind-tables",             "-fmerge-all-constants",    "-fno-builtin-fwrite",
        "-fno-builtin-fread",          "-DJPEGXL_ENABLE_SKCMS=1",  "-DJPEGXL_ENABLE_TRANSCODE_JPEG=1",
        "-DJPEGXL_ENABLE_BOXES=1",     "-DHWY_STATIC_DEFINE",
    }) catch @panic("OOM");
    if (!c.isWindows()) flags.appendSlice(b.allocator, &.{
        "-fno-omit-frame-pointer", "-fsized-deallocation", "-fno-exceptions",    "-fmath-errno",
        "-fnew-alignment=8",       "-fno-cxx-exceptions",  "-fno-slp-vectorize", "-fno-vectorize",
    }) catch @panic("OOM");

    const setup: Ctx.Setup = .{
        .config_headers = &.{version},
        .includes = &.{ src.path(""), src.path("lib/include"), hwy_src.path(""), brotli_src.path("c/include"), exports.getDirectory() },
    };
    const skcms_setup: Ctx.Setup = .{
        .config_headers = setup.config_headers,
        .includes = std.mem.concat(b.allocator, std.Build.LazyPath, &.{ setup.includes, &.{skcms.path("")} }) catch @panic("OOM"),
    };

    const jxl_flags = withFlags(b, flags.items, &.{ "-DJXL_STATIC_DEFINE", "-DJXL_INTERNAL_LIBRARY_BUILD" });
    const jxl_mod = c.module(.{ .cpp = true });
    setup.apply(jxl_mod);
    jxl_mod.addCSourceFiles(.{ .root = src.path("lib"), .files = &(jxl_dec ++ jxl_dec_jpeg ++ jxl_dec_box ++ jxl_enc), .flags = jxl_flags });
    jxl_mod.addCSourceFiles(.{ .root = src.path("lib"), .files = &.{"jxl/enc_fast_lossless.cc"}, .flags = withFlags(b, jxl_flags, &.{"-O3"}) });
    const jxl = c.staticLibrary("jxl", jxl_mod);

    const threads_mod = c.module(.{ .cpp = true });
    setup.apply(threads_mod);
    threads_mod.addCSourceFiles(.{
        .root = src.path("lib"),
        .files = &.{ "threads/resizable_parallel_runner.cc", "threads/thread_parallel_runner.cc", "threads/thread_parallel_runner_internal.cc" },
        .flags = withFlags(b, flags.items, &.{ "-DJXL_THREADS_STATIC_DEFINE", "-DJXL_THREADS_INTERNAL_LIBRARY_BUILD" }),
    });
    const threads = c.staticLibrary("jxl_threads", threads_mod);

    var cms_flags: std.ArrayList([]const u8) = .empty;
    cms_flags.appendSlice(b.allocator, flags.items) catch @panic("OOM");
    cms_flags.appendSlice(b.allocator, &.{ "-DJXL_STATIC_DEFINE", "-DJXL_CMS_STATIC_DEFINE", "-Wno-psabi" }) catch @panic("OOM");
    if (c.target.result.os.tag == .windows and c.target.result.abi.isGnu()) cms_flags.append(b.allocator, "-DSKCMS_HAS_MUSTTAIL=0") catch @panic("OOM");
    if (!x86) cms_flags.appendSlice(b.allocator, &.{ "-DSKCMS_DISABLE_HSW", "-DSKCMS_DISABLE_SKX" }) catch @panic("OOM");
    const cms_mod = c.module(.{ .cpp = true });
    skcms_setup.apply(cms_mod);
    cms_mod.addCSourceFiles(.{ .root = src.path("lib"), .files = &.{"jxl/cms/jxl_cms.cc"}, .flags = cms_flags.items });
    cms_mod.addCSourceFiles(.{ .root = skcms.path(""), .files = &.{ "skcms.cc", "src/skcms_TransformBaseline.cc" }, .flags = cms_flags.items });
    if (x86) {
        const kernels = [_]struct { name: []const u8, file: []const u8, features: []const std.Target.x86.Feature }{
            .{ .name = "skcms_hsw", .file = "src/skcms_TransformHsw.cc", .features = &.{ .avx2, .f16c } },
            .{ .name = "skcms_skx", .file = "src/skcms_TransformSkx.cc", .features = &.{ .avx512f, .avx512dq, .avx512cd, .avx512bw, .avx512vl } },
        };
        for (kernels) |k| {
            c.addSources(cms_mod, k.name, .{
                .module = .{ .cpp = true, .x86_features = k.features },
                .setup = skcms_setup,
                .groups = &.{.{ .root = skcms.path(""), .files = &.{k.file}, .flags = cms_flags.items }},
            });
        }
    }
    const cms = c.staticLibrary("jxl_cms", cms_mod);

    for (public_headers) |h| jxl.installHeader(src.path(b.fmt("lib/include/jxl/{s}", .{h})), b.fmt("jxl/{s}", .{h}));
    jxl.installConfigHeader(version);
    jxl.installHeader(exports.getDirectory().path(b, "jxl/jxl_export.h"), "jxl/jxl_export.h");
    jxl.installHeader(exports.getDirectory().path(b, "jxl/jxl_cms_export.h"), "jxl/jxl_cms_export.h");
    for (threads_headers) |h| jxl.installHeader(src.path(b.fmt("lib/include/jxl/{s}", .{h})), b.fmt("jxl/{s}", .{h}));
    jxl.installHeader(exports.getDirectory().path(b, "jxl/jxl_threads_export.h"), "jxl/jxl_threads_export.h");

    return c.package(&.{
        .{ .lib = jxl, .links = &.{"jxl_cms"} },
        .{ .lib = threads },
        .{ .lib = cms },
    });
}

fn withFlags(b: *std.Build, base: []const []const u8, extra: []const []const u8) []const []const u8 {
    return std.mem.concat(b.allocator, []const u8, &.{ base, extra }) catch @panic("OOM");
}

/// The text CMake's generate_export_header writes for a static library, which is all that is built.
fn exportHeader(b: *std.Build, prefix: []const u8, static_define: []const u8, export_attr: []const u8, hidden_attr: []const u8) []const u8 {
    return b.fmt(
        \\#ifndef {0s}_EXPORT_H
        \\#define {0s}_EXPORT_H
        \\
        \\#ifdef {1s}
        \\#  define {0s}_EXPORT
        \\#  define {0s}_NO_EXPORT
        \\#else
        \\#  ifndef {0s}_EXPORT
        \\#    define {0s}_EXPORT {2s}
        \\#  endif
        \\
        \\#  ifndef {0s}_NO_EXPORT
        \\#    define {0s}_NO_EXPORT {3s}
        \\#  endif
        \\#endif
        \\
        \\#ifndef {0s}_DEPRECATED
        \\#  define {0s}_DEPRECATED __attribute__ ((__deprecated__))
        \\#endif
        \\
        \\#ifndef {0s}_DEPRECATED_EXPORT
        \\#  define {0s}_DEPRECATED_EXPORT {0s}_EXPORT {0s}_DEPRECATED
        \\#endif
        \\
        \\#ifndef {0s}_DEPRECATED_NO_EXPORT
        \\#  define {0s}_DEPRECATED_NO_EXPORT {0s}_NO_EXPORT {0s}_DEPRECATED
        \\#endif
        \\
        \\#endif /* {0s}_EXPORT_H */
        \\
    , .{ prefix, static_define, export_attr, hidden_attr });
}

const public_headers = [_][]const u8{
    "cms.h",            "cms_interface.h",   "codestream_header.h", "color_encoding.h", "compressed_icc.h",
    "decode.h",         "decode_cxx.h",      "encode.h",            "encode_cxx.h",     "gain_map.h",
    "memory_manager.h", "parallel_runner.h", "stats.h",             "types.h",
};

const threads_headers = [_][]const u8{
    "resizable_parallel_runner.h", "resizable_parallel_runner_cxx.h", "thread_parallel_runner.h", "thread_parallel_runner_cxx.h",
};

const jxl_dec_jpeg = [_][]const u8{ "jxl/decode_to_jpeg.cc", "jxl/jpeg/dec_jpeg_data.cc", "jxl/jpeg/dec_jpeg_data_writer.cc", "jxl/jpeg/jpeg_data.cc" };

const jxl_dec_box = [_][]const u8{"jxl/box_content_decoder.cc"};

const jxl_dec = [_][]const u8{
    "jxl/ac_strategy.cc", "jxl/alpha.cc", "jxl/ans_common.cc", "jxl/blending.cc", "jxl/chroma_from_luma.cc", "jxl/coeff_order.cc", "jxl/color_encoding_internal.cc", "jxl/compressed_dc.cc", "jxl/convolve_slow.cc", "jxl/convolve_symmetric5.cc", "jxl/dct_scales.cc", "jxl/dec_ans.cc", "jxl/dec_bit_reader.cc", "jxl/dec_cache.cc", "jxl/dec_context_map.cc", "jxl/dec_external_image.cc", "jxl/dec_frame.cc", "jxl/dec_group.cc", "jxl/dec_group_border.cc", "jxl/dec_huffman.cc", "jxl/dec_modular.cc", "jxl/dec_noise.cc", "jxl/dec_patch_dictionary.cc", "jxl/dec_xyb.cc", "jxl/decode.cc", "jxl/entropy_coder.cc", "jxl/epf.cc", "jxl/fields.cc", "jxl/frame_header.cc", "jxl/headers.cc", "jxl/huffman_table.cc", "jxl/icc_codec.cc", "jxl/icc_codec_common.cc", "jxl/image.cc", "jxl/image_bundle.cc", "jxl/image_metadata.cc", "jxl/image_ops.cc", "jxl/loop_filter.cc", "jxl/luminance.cc", "jxl/memory_manager_internal.cc", "jxl/modular/encoding/dec_ma.cc", "jxl/modular/encoding/encoding.cc", "jxl/modular/modular_image.cc", "jxl/modular/transform/palette.cc", "jxl/modular/transform/rct.cc", "jxl/modular/transform/squeeze.cc", "jxl/modular/transform/squeeze_params.cc", "jxl/modular/transform/transform.cc", "jxl/opsin_params.cc", "jxl/passes_state.cc", "jxl/quant_weights.cc", "jxl/quantizer.cc", "jxl/render_pipeline/low_memory_render_pipeline.cc", "jxl/render_pipeline/render_pipeline.cc", "jxl/render_pipeline/render_pipeline_stage.cc", "jxl/render_pipeline/simple_render_pipeline.cc", "jxl/render_pipeline/stage_blending.cc", "jxl/render_pipeline/stage_chroma_upsampling.cc", "jxl/render_pipeline/stage_cms.cc", "jxl/render_pipeline/stage_epf.cc", "jxl/render_pipeline/stage_from_linear.cc", "jxl/render_pipeline/stage_gaborish.cc", "jxl/render_pipeline/stage_noise.cc", "jxl/render_pipeline/stage_patches.cc", "jxl/render_pipeline/stage_splines.cc", "jxl/render_pipeline/stage_spot.cc", "jxl/render_pipeline/stage_to_linear.cc", "jxl/render_pipeline/stage_tone_mapping.cc", "jxl/render_pipeline/stage_upsampling.cc", "jxl/render_pipeline/stage_write.cc", "jxl/render_pipeline/stage_xyb.cc", "jxl/render_pipeline/stage_ycbcr.cc", "jxl/simd_util.cc", "jxl/splines.cc", "jxl/toc.cc",
};

const jxl_enc = [_][]const u8{
    "jxl/butteraugli/butteraugli.cc", "jxl/enc_ac_strategy.cc", "jxl/enc_adaptive_quantization.cc", "jxl/enc_ans.cc", "jxl/enc_ans_simd.cc", "jxl/enc_aux_out.cc", "jxl/enc_bit_writer.cc", "jxl/enc_butteraugli_comparator.cc", "jxl/enc_cache.cc", "jxl/enc_chroma_from_luma.cc", "jxl/enc_cluster.cc", "jxl/enc_coeff_order.cc", "jxl/enc_comparator.cc", "jxl/enc_context_map.cc", "jxl/enc_convolve_separable5.cc", "jxl/enc_debug_image.cc", "jxl/enc_detect_dots.cc", "jxl/enc_dot_dictionary.cc", "jxl/enc_entropy_coder.cc", "jxl/enc_external_image.cc", "jxl/enc_fields.cc", "jxl/enc_frame.cc", "jxl/enc_gaborish.cc", "jxl/enc_group.cc", "jxl/enc_heuristics.cc", "jxl/enc_huffman.cc", "jxl/enc_huffman_tree.cc", "jxl/enc_icc_codec.cc", "jxl/enc_image_bundle.cc", "jxl/enc_linalg.cc", "jxl/enc_lz77.cc", "jxl/enc_modular.cc", "jxl/enc_modular_simd.cc", "jxl/enc_noise.cc", "jxl/enc_patch_dictionary.cc", "jxl/enc_photon_noise.cc", "jxl/enc_progressive_split.cc", "jxl/enc_quant_weights.cc", "jxl/enc_splines.cc", "jxl/enc_toc.cc", "jxl/enc_transforms.cc", "jxl/enc_xyb.cc", "jxl/encode.cc", "jxl/jpeg/enc_jpeg_data.cc", "jxl/jpeg/enc_jpeg_data_reader.cc", "jxl/jpeg/enc_jpeg_huffman_decode.cc", "jxl/modular/encoding/enc_debug_tree.cc", "jxl/modular/encoding/enc_encoding.cc", "jxl/modular/encoding/enc_ma.cc", "jxl/modular/transform/enc_palette.cc", "jxl/modular/transform/enc_rct.cc", "jxl/modular/transform/enc_squeeze.cc", "jxl/modular/transform/enc_transform.cc",
};
