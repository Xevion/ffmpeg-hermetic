const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// zimg (C++). Each x86 instruction set level is its own object, picked at runtime from cpuid.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const src = c.upstream("zimg");
    const x86 = c.arch() == .x86_64;
    // Under _MSC_VER the NEON sources use cl.exe workarounds that clang's arm_neon.h rejects, so windows-msvc aarch64 is C only.
    const arm = c.arch() == .aarch64 and !c.isMsvc();

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(c.b.allocator, &.{ "-std=c++14", "-DNDEBUG", "-fvisibility=hidden" }) catch @panic("OOM");
    if (x86) flags.appendSlice(c.b.allocator, &.{ "-DZIMG_X86", "-DZIMG_X86_AVX512" }) catch @panic("OOM");
    if (arm) flags.append(c.b.allocator, "-DZIMG_ARM") catch @panic("OOM");

    const setup: Ctx.Setup = .{ .includes = &.{src.path("src/zimg")} };

    const mod = c.module(.{ .cpp = true });
    setup.apply(mod);
    mod.addCSourceFiles(.{ .root = src.path("src/zimg"), .files = &common, .flags = flags.items });
    if (x86) {
        mod.addCSourceFiles(.{ .root = src.path("src/zimg"), .files = &(x86_base ++ sse ++ sse2), .flags = flags.items });
        const isas = [_]struct { name: []const u8, features: []const std.Target.x86.Feature, files: []const []const u8 }{
            .{ .name = "avx", .features = &.{.avx}, .files = &avx },
            .{ .name = "f16c", .features = &.{ .avx, .f16c }, .files = &f16c },
            .{ .name = "avx2", .features = &.{ .avx2, .f16c, .fma }, .files = &avx2 },
            .{ .name = "avx512", .features = &.{ .avx512f, .avx512cd, .avx512vl, .avx512bw, .avx512dq }, .files = &avx512 },
            .{ .name = "avx512_vnni", .features = &.{ .avx512f, .avx512cd, .avx512vl, .avx512bw, .avx512dq, .avx512vnni }, .files = &avx512_vnni },
        };
        for (isas) |isa| {
            c.addSources(mod, c.b.fmt("zimg_{s}", .{isa.name}), .{
                .module = .{ .cpp = true, .x86_features = isa.features },
                .setup = setup,
                .groups = &.{.{ .root = src.path("src/zimg"), .files = isa.files, .flags = flags.items }},
            });
        }
    }
    if (arm) mod.addCSourceFiles(.{ .root = src.path("src/zimg"), .files = &(arm_files ++ neon), .flags = flags.items });

    const lib = c.staticLibrary("zimg", mod);
    lib.installHeader(src.path("src/zimg/api/zimg.h"), "zimg.h");
    lib.installHeader(src.path("src/zimg/api/zimg++.hpp"), "zimg++.hpp");
    return c.single(lib);
}

const common = [_][]const u8{
    "api/zimg.cpp",
    "colorspace/colorspace.cpp",
    "colorspace/colorspace_param.cpp",
    "colorspace/gamma.cpp",
    "colorspace/graph.cpp",
    "colorspace/matrix3.cpp",
    "colorspace/operation.cpp",
    "colorspace/operation_impl.cpp",
    "common/cpuinfo.cpp",
    "common/libm_wrapper.cpp",
    "common/matrix.cpp",
    "depth/blue.cpp",
    "depth/depth_convert.cpp",
    "depth/depth.cpp",
    "depth/dither.cpp",
    "depth/quantize.cpp",
    "graph/basic_filter.cpp",
    "graph/filtergraph.cpp",
    "graph/graphbuilder.cpp",
    "graph/graphnode.cpp",
    "resize/filter.cpp",
    "resize/resize.cpp",
    "resize/resize_impl.cpp",
    "unresize/bilinear.cpp",
    "unresize/unresize.cpp",
    "unresize/unresize_impl.cpp",
};

const x86_base = [_][]const u8{
    "colorspace/x86/operation_impl_x86.cpp",
    "common/x86/cpuinfo_x86.cpp",
    "common/x86/x86util.cpp",
    "depth/x86/depth_convert_x86.cpp",
    "depth/x86/dither_x86.cpp",
    "resize/x86/resize_impl_x86.cpp",
};

const sse = [_][]const u8{
    "colorspace/x86/operation_impl_sse.cpp",
    "resize/x86/resize_impl_sse.cpp",
};

const sse2 = [_][]const u8{
    "colorspace/x86/operation_impl_sse2.cpp",
    "depth/x86/depth_convert_sse2.cpp",
    "depth/x86/dither_sse2.cpp",
    "depth/x86/error_diffusion_sse2.cpp",
    "depth/x86/f16c_sse2.cpp",
    "resize/x86/resize_impl_sse2.cpp",
};

const avx = [_][]const u8{
    "colorspace/x86/operation_impl_avx.cpp",
    "resize/x86/resize_impl_avx.cpp",
};

const f16c = [_][]const u8{"depth/x86/f16c_ivb.cpp"};

const avx2 = [_][]const u8{
    "colorspace/x86/operation_impl_avx2.cpp",
    "depth/x86/depth_convert_avx2.cpp",
    "depth/x86/dither_avx2.cpp",
    "depth/x86/error_diffusion_avx2.cpp",
    "resize/x86/resize_impl_avx2.cpp",
};

const avx512 = [_][]const u8{
    "colorspace/x86/gamma_constants_avx512.cpp",
    "colorspace/x86/operation_impl_avx512.cpp",
    "depth/x86/depth_convert_avx512.cpp",
    "depth/x86/dither_avx512.cpp",
    "resize/x86/resize_impl_avx512.cpp",
};

const avx512_vnni = [_][]const u8{"resize/x86/resize_impl_avx512_vnni.cpp"};

const arm_files = [_][]const u8{
    "colorspace/arm/operation_impl_arm.cpp",
    "common/arm/cpuinfo_arm.cpp",
    "common/arm/neon_util.cpp",
    "depth/arm/depth_convert_arm.cpp",
    "depth/arm/dither_arm.cpp",
    "resize/arm/resize_impl_arm.cpp",
};

const neon = [_][]const u8{
    "colorspace/arm/operation_impl_neon.cpp",
    "depth/arm/depth_convert_neon.cpp",
    "depth/arm/dither_neon.cpp",
    "depth/arm/f16c_neon.cpp",
    "resize/arm/resize_impl_neon.cpp",
};
