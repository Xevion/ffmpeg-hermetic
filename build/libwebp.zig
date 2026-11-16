const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

const version = "1.6.0";

/// libwebp (with the decoder and encoder), libsharpyuv, libwebpmux and libwebpdemux.
pub fn build(c: Ctx, _: Nasm) []const *std.Build.Step.Compile {
    const b = c.b;
    const src = c.upstream("libwebp");
    const x86 = c.arch() == .x86_64;
    const arm = c.arch() == .aarch64;
    const msvc_like = c.isWindows();

    const config = b.addConfigHeader(.{ .style = .blank, .include_path = "src/webp/config.h" }, .{
        .HAVE_BUILTIN_BSWAP16 = @as(?i64, if (msvc_like) null else 1),
        .HAVE_BUILTIN_BSWAP32 = @as(?i64, if (msvc_like) null else 1),
        .HAVE_BUILTIN_BSWAP64 = @as(?i64, if (msvc_like) null else 1),
        .HAVE_UNISTD_H = @as(?i64, if (msvc_like) null else 1),
        .HAVE_WINDOWS_H = @as(?i64, if (msvc_like) 1 else null),
        .PACKAGE = "WebP",
        .PACKAGE_NAME = "WebP",
        .PACKAGE_STRING = "WebP " ++ version,
        .PACKAGE_TARNAME = "WebP",
        .PACKAGE_VERSION = version,
        .VERSION = version,
        .WEBP_HAVE_SSE2 = @as(?i64, if (x86) 1 else null),
        .WEBP_HAVE_SSE41 = @as(?i64, if (x86) 1 else null),
        .WEBP_HAVE_AVX2 = @as(?i64, if (x86) 1 else null),
        .WEBP_HAVE_NEON = @as(?i64, if (arm) 1 else null),
        .WEBP_NEAR_LOSSLESS = 1,
        .WEBP_USE_THREAD = 1,
    });
    const flags: []const []const u8 = &.{ "-DHAVE_CONFIG_H", "-DNDEBUG", "-fvisibility=hidden" };

    const setup = struct {
        fn f(m: *std.Build.Module, s: *std.Build.Dependency, cfg: *std.Build.Step.ConfigHeader) void {
            m.addConfigHeader(cfg);
            m.addIncludePath(s.path(""));
            m.addIncludePath(s.path("src"));
        }
    }.f;

    const webp_mod = c.module(.{});
    setup(webp_mod, src, config);
    webp_mod.addCSourceFiles(.{ .root = src.path(""), .files = &(dec ++ dsp_common ++ dsp_enc ++ utils ++ enc), .flags = flags });
    if (x86) {
        webp_mod.addCSourceFiles(.{ .root = src.path(""), .files = &x86_sse2, .flags = flags });
        c.addObjectsTo(webp_mod, "webp_sse41", .{
            .module = .{ .x86_features = &.{.sse4_1} },
            .root = src.path(""),
            .groups = &.{.{ .files = &x86_sse41, .flags = flags }},
        }, setup, .{ src, config });
        c.addObjectsTo(webp_mod, "webp_avx2", .{
            .module = .{ .x86_features = &.{ .avx, .avx2 } },
            .root = src.path(""),
            .groups = &.{.{ .files = &x86_avx2, .flags = flags }},
        }, setup, .{ src, config });
    }
    if (arm) webp_mod.addCSourceFiles(.{ .root = src.path(""), .files = &neon, .flags = flags });
    const webp = c.staticLibrary("webp", webp_mod);
    for ([_][]const u8{ "decode.h", "encode.h", "types.h" }) |h| {
        webp.installHeader(src.path(b.fmt("src/webp/{s}", .{h})), b.fmt("webp/{s}", .{h}));
    }

    const sharpyuv_mod = c.module(.{});
    setup(sharpyuv_mod, src, config);
    sharpyuv_mod.addCSourceFiles(.{ .root = src.path("sharpyuv"), .files = &sharpyuv, .flags = flags });
    if (x86) sharpyuv_mod.addCSourceFiles(.{ .root = src.path("sharpyuv"), .files = &.{"sharpyuv_sse2.c"}, .flags = flags });
    if (arm) sharpyuv_mod.addCSourceFiles(.{ .root = src.path("sharpyuv"), .files = &.{"sharpyuv_neon.c"}, .flags = flags });
    const sharpyuv_lib = c.staticLibrary("sharpyuv", sharpyuv_mod);
    for ([_][]const u8{ "sharpyuv.h", "sharpyuv_csp.h" }) |h| {
        sharpyuv_lib.installHeader(src.path(b.fmt("sharpyuv/{s}", .{h})), b.fmt("webp/sharpyuv/{s}", .{h}));
    }

    const mux_mod = c.module(.{});
    setup(mux_mod, src, config);
    mux_mod.addCSourceFiles(.{ .root = src.path("src/mux"), .files = &mux, .flags = flags });
    const mux_lib = c.staticLibrary("webpmux", mux_mod);
    for ([_][]const u8{ "mux.h", "mux_types.h", "types.h" }) |h| {
        mux_lib.installHeader(src.path(b.fmt("src/webp/{s}", .{h})), b.fmt("webp/{s}", .{h}));
    }

    const demux_mod = c.module(.{});
    setup(demux_mod, src, config);
    demux_mod.addCSourceFiles(.{ .root = src.path("src/demux"), .files = &demux, .flags = flags });
    const demux_lib = c.staticLibrary("webpdemux", demux_mod);
    for ([_][]const u8{ "demux.h", "mux_types.h", "decode.h", "types.h" }) |h| {
        demux_lib.installHeader(src.path(b.fmt("src/webp/{s}", .{h})), b.fmt("webp/{s}", .{h}));
    }

    return b.allocator.dupe(*std.Build.Step.Compile, &.{ webp, sharpyuv_lib, mux_lib, demux_lib }) catch @panic("OOM");
}

const sharpyuv = [_][]const u8{
    "sharpyuv.c", "sharpyuv_cpu.c", "sharpyuv_csp.c", "sharpyuv_dsp.c", "sharpyuv_gamma.c",
};

const dec = [_][]const u8{
    "src/dec/alpha_dec.c", "src/dec/buffer_dec.c", "src/dec/frame_dec.c", "src/dec/idec_dec.c",
    "src/dec/io_dec.c",    "src/dec/quant_dec.c",  "src/dec/tree_dec.c",  "src/dec/vp8_dec.c",
    "src/dec/vp8l_dec.c",  "src/dec/webp_dec.c",
};

const enc = [_][]const u8{
    "src/enc/alpha_enc.c",               "src/enc/analysis_enc.c",      "src/enc/backward_references_cost_enc.c",
    "src/enc/backward_references_enc.c", "src/enc/config_enc.c",        "src/enc/cost_enc.c",
    "src/enc/filter_enc.c",              "src/enc/frame_enc.c",         "src/enc/histogram_enc.c",
    "src/enc/iterator_enc.c",            "src/enc/near_lossless_enc.c", "src/enc/picture_enc.c",
    "src/enc/picture_csp_enc.c",         "src/enc/picture_psnr_enc.c",  "src/enc/picture_rescale_enc.c",
    "src/enc/picture_tools_enc.c",       "src/enc/predictor_enc.c",     "src/enc/quant_enc.c",
    "src/enc/syntax_enc.c",              "src/enc/token_enc.c",         "src/enc/tree_enc.c",
    "src/enc/vp8l_enc.c",                "src/enc/webp_enc.c",
};

const dsp_common = [_][]const u8{
    "src/dsp/alpha_processing.c", "src/dsp/cpu.c",      "src/dsp/dec.c",      "src/dsp/dec_clip_tables.c",
    "src/dsp/filters.c",          "src/dsp/lossless.c", "src/dsp/rescaler.c", "src/dsp/upsampling.c",
    "src/dsp/yuv.c",
};

const dsp_enc = [_][]const u8{
    "src/dsp/cost.c", "src/dsp/enc.c", "src/dsp/lossless_enc.c", "src/dsp/ssim.c",
};

const utils = [_][]const u8{
    "src/utils/bit_reader_utils.c",   "src/utils/color_cache_utils.c", "src/utils/filters_utils.c",
    "src/utils/huffman_utils.c",      "src/utils/palette.c",           "src/utils/quant_levels_dec_utils.c",
    "src/utils/rescaler_utils.c",     "src/utils/random_utils.c",      "src/utils/thread_utils.c",
    "src/utils/utils.c",              "src/utils/bit_writer_utils.c",  "src/utils/huffman_encode_utils.c",
    "src/utils/quant_levels_utils.c",
};

const x86_sse2 = [_][]const u8{
    "src/dsp/alpha_processing_sse2.c", "src/dsp/dec_sse2.c",      "src/dsp/filters_sse2.c",
    "src/dsp/lossless_sse2.c",         "src/dsp/rescaler_sse2.c", "src/dsp/upsampling_sse2.c",
    "src/dsp/yuv_sse2.c",              "src/dsp/cost_sse2.c",     "src/dsp/enc_sse2.c",
    "src/dsp/lossless_enc_sse2.c",     "src/dsp/ssim_sse2.c",
};

const x86_sse41 = [_][]const u8{
    "src/dsp/alpha_processing_sse41.c", "src/dsp/dec_sse41.c", "src/dsp/lossless_sse41.c",
    "src/dsp/upsampling_sse41.c",       "src/dsp/yuv_sse41.c", "src/dsp/enc_sse41.c",
    "src/dsp/lossless_enc_sse41.c",
};

const x86_avx2 = [_][]const u8{ "src/dsp/lossless_avx2.c", "src/dsp/lossless_enc_avx2.c" };

const neon = [_][]const u8{
    "src/dsp/alpha_processing_neon.c", "src/dsp/dec_neon.c",      "src/dsp/filters_neon.c",
    "src/dsp/lossless_neon.c",         "src/dsp/rescaler_neon.c", "src/dsp/upsampling_neon.c",
    "src/dsp/yuv_neon.c",              "src/dsp/cost_neon.c",     "src/dsp/enc_neon.c",
    "src/dsp/lossless_enc_neon.c",
};

const mux = [_][]const u8{ "anim_encode.c", "muxedit.c", "muxinternal.c", "muxread.c" };

const demux = [_][]const u8{ "anim_decode.c", "demux.c" };
