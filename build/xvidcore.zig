const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// Xvid's MPEG-4 ASP codec. The x86_64 MMX, SSE and SSE2 routines are picked at runtime from cpuid.
pub fn build(c: Ctx, nasm: Nasm) ?Ctx.Output {
    const b = c.b;
    const src = c.lazyUpstream("xvidcore") orelse return null;
    const t = c.target.result;
    const x86 = c.arch() == .x86_64;

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{
        "-ffast-math",             "-finline-functions", "-fomit-frame-pointer",
        "-DARCH_IS_LITTLE_ENDIAN", "-DARCH_IS_64BIT",
    }) catch @panic("OOM");
    flags.append(b.allocator, if (x86) "-DARCH_IS_X86_64" else "-DARCH_IS_GENERIC") catch @panic("OOM");
    if (!c.isWindows()) flags.append(b.allocator, "-DHAVE_PTHREAD") catch @panic("OOM");
    if (c.isMsvc()) flags.appendSlice(b.allocator, &.{ "-DWIN32", "-fms-extensions", "-D_except=__except" }) catch @panic("OOM");

    const mod = c.module(.{});
    mod.addCSourceFiles(.{ .root = src.path("src"), .files = &sources, .flags = flags.items });
    if (!c.isWindows()) mod.linkSystemLibrary("m", .{});

    if (x86) {
        var asm_flags: std.ArrayList([]const u8) = .empty;
        asm_flags.append(b.allocator, "-DARCH_IS_X86_64") catch @panic("OOM");
        switch (t.os.tag) {
            .windows => asm_flags.appendSlice(b.allocator, &.{ "-DWINDOWS", "-DNO_PREFIX" }) catch @panic("OOM"),
            .macos, .ios, .tvos, .watchos, .visionos => asm_flags.append(b.allocator, "-DPREFIX") catch @panic("OOM"),
            else => asm_flags.append(b.allocator, "-DMARK_FUNCS") catch @panic("OOM"),
        }
        nasm.addFiles(c, mod, .{
            .root = src.path("src"),
            .files = &asm_sources,
            .include_dirs = &.{ src.path("src"), src.path("src/image/x86_asm") },
            .flags = asm_flags.items,
        });
    }

    const lib = c.staticLibrary("xvidcore", mod);
    lib.installHeader(src.path("src/xvid.h"), "xvid.h");
    return c.single(lib);
}

const sources = [_][]const u8{
    "decoder.c",
    "encoder.c",
    "xvid.c",
    "bitstream/bitstream.c",
    "bitstream/cbp.c",
    "bitstream/mbcoding.c",
    "dct/fdct.c",
    "dct/idct.c",
    "dct/simple_idct.c",
    "image/colorspace.c",
    "image/image.c",
    "image/interpolate8x8.c",
    "image/font.c",
    "image/postprocessing.c",
    "image/qpel.c",
    "image/reduced.c",
    "motion/estimation_bvop.c",
    "motion/estimation_common.c",
    "motion/estimation_gmc.c",
    "motion/estimation_pvop.c",
    "motion/estimation_rd_based.c",
    "motion/estimation_rd_based_bvop.c",
    "motion/gmc.c",
    "motion/motion_comp.c",
    "motion/vop_type_decision.c",
    "motion/sad.c",
    "prediction/mbprediction.c",
    "plugins/plugin_single.c",
    "plugins/plugin_2pass1.c",
    "plugins/plugin_2pass2.c",
    "plugins/plugin_lumimasking.c",
    "plugins/plugin_dump.c",
    "plugins/plugin_psnr.c",
    "plugins/plugin_ssim.c",
    "plugins/plugin_psnrhvsm.c",
    "quant/quant_h263.c",
    "quant/quant_matrix.c",
    "quant/quant_mpeg.c",
    "utils/emms.c",
    "utils/mbtransquant.c",
    "utils/mem_align.c",
    "utils/mem_transfer.c",
    "utils/timer.c",
};

const asm_sources = [_][]const u8{
    "bitstream/x86_asm/cbp_mmx.asm",
    "bitstream/x86_asm/cbp_sse2.asm",
    "dct/x86_asm/fdct_mmx_ffmpeg.asm",
    "dct/x86_asm/fdct_mmx_skal.asm",
    "dct/x86_asm/fdct_sse2_skal.asm",
    "dct/x86_asm/idct_3dne.asm",
    "dct/x86_asm/idct_mmx.asm",
    "dct/x86_asm/idct_sse2_dmitry.asm",
    "image/x86_asm/colorspace_rgb_mmx.asm",
    "image/x86_asm/colorspace_yuv_mmx.asm",
    "image/x86_asm/colorspace_yuyv_mmx.asm",
    "image/x86_asm/interpolate8x8_3dn.asm",
    "image/x86_asm/interpolate8x8_3dne.asm",
    "image/x86_asm/interpolate8x8_mmx.asm",
    "image/x86_asm/interpolate8x8_xmm.asm",
    "image/x86_asm/postprocessing_mmx.asm",
    "image/x86_asm/postprocessing_sse2.asm",
    "image/x86_asm/reduced_mmx.asm",
    "image/x86_asm/qpel_mmx.asm",
    "image/x86_asm/gmc_mmx.asm",
    "image/x86_asm/deintl_sse.asm",
    "motion/x86_asm/sad_xmm.asm",
    "motion/x86_asm/sad_sse2.asm",
    "motion/x86_asm/sad_mmx.asm",
    "motion/x86_asm/sad_3dne.asm",
    "motion/x86_asm/sad_3dn.asm",
    "quant/x86_asm/quantize_h263_mmx.asm",
    "quant/x86_asm/quantize_h263_3dne.asm",
    "quant/x86_asm/quantize_mpeg_xmm.asm",
    "quant/x86_asm/quantize_mpeg_mmx.asm",
    "utils/x86_asm/mem_transfer_mmx.asm",
    "utils/x86_asm/mem_transfer_3dne.asm",
    "utils/x86_asm/interlacing_mmx.asm",
    "utils/x86_asm/cpuid.asm",
    "plugins/x86_asm/plugin_ssim-a.asm",
};
