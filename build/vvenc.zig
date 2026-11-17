const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "vvenc",
    .version = "1.14.0",
    .licenses = &.{"LICENSE.txt"},
    .ffmpeg = &.{"libvvenc"},
    .system_libs = .{ .linux = &.{ "m", "pthread" } },
};

/// VVenC, the H.266/VVC encoder (C++). Each x86 instruction set level is its own object,
/// picked at runtime from cpuid; other architectures run the same kernels through SIMDe.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const ver = Meta.versionParts(meta.version);
    const b = c.b;
    const src = c.upstream("vvenc");
    const x86 = c.arch() == .x86_64;
    const arm = c.arch() == .aarch64;

    const version = b.addConfigHeader(.{
        .style = .{ .cmake = src.path("source/Lib/vvenc/version.h.in") },
        .include_path = "vvenc/version.h",
    }, .{ .PROJECT_VERSION_MAJOR = ver[0], .PROJECT_VERSION_MINOR = ver[1], .PROJECT_VERSION_PATCH = ver[2] });
    const api = b.addConfigHeader(.{
        .style = .{ .cmake = src.path("include/vvenc/vvenc.h.in") },
        .include_path = "vvenc/vvenc.h",
    }, .{ .VVENC_USE_UNSTABLE_API = 0 });

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{
        "-std=gnu++14",   "-fvisibility=hidden", "-fvisibility-inlines-hidden",
        "-DVVENC_SOURCE", "-DTARGET_SIMD_X86=1", "-DVVENC_ENABLE_THIRDPARTY_JSON",
    }) catch @panic("OOM");
    flags.append(b.allocator, if (c.isWindows()) "-D_WIN32_WINNT=0x0600" else "-DHAVE_PTHREADS") catch @panic("OOM");
    if (arm) flags.appendSlice(b.allocator, &.{ "-DTARGET_SIMD_ARM=1", "-DTARGET_SIMD_ARM_SVE=1", "-fno-lax-vector-conversions" }) catch @panic("OOM");

    const setup: Ctx.Setup = .{
        .config_headers = &.{ version, api },
        .includes = std.mem.concat(b.allocator, std.Build.LazyPath, &.{
            &.{ src.path("include"), src.path("source/Lib") },
            c.includeDirs(src.path("source/Lib"), &.{ "vvenc", "DecoderLib", "EncoderLib", "CommonLib", "CommonLib/x86", "CommonLib/arm", "apputils" }),
            &.{ src.path("thirdparty"), src.path("thirdparty/nlohmann_json/single_include") },
        }) catch @panic("OOM"),
    };
    const root = src.path("source/Lib");

    const mod = c.module(.{ .cpp = true });
    setup.apply(mod);
    mod.addCSourceFiles(.{ .root = root, .files = &common, .flags = flags.items });

    const isas = [_]struct { name: []const u8, define: ?[]const u8 = null, x86_features: []const std.Target.x86.Feature = &.{}, files: []const []const u8 }{
        .{ .name = "vvenc_common_sse41", .x86_features = &.{.sse4_1}, .files = &common_sse41 },
        .{ .name = "vvenc_x86", .x86_features = &.{.xsave}, .files = &x86_xsave },
        .{ .name = "vvenc_sse41", .define = "-DUSE_SSE41", .x86_features = &.{.sse4_1}, .files = &x86_sse41 },
        .{ .name = "vvenc_sse42", .define = "-DUSE_SSE42", .x86_features = &.{.sse4_2}, .files = &x86_sse42 },
        .{ .name = "vvenc_avx2", .define = "-DUSE_AVX2", .x86_features = &.{.avx2}, .files = &x86_avx2 },
    };
    if (x86) {
        for (isas) |isa| {
            c.addSources(mod, isa.name, .{
                .module = .{ .cpp = true, .x86_features = isa.x86_features },
                .setup = setup,
                .groups = &.{.{ .root = root, .files = isa.files, .flags = withDefine(b, flags.items, isa.define) }},
            });
        }
    } else {
        mod.addCSourceFiles(.{ .root = root, .files = &common_sse41, .flags = flags.items });
        mod.addCSourceFiles(.{ .root = root, .files = &x86_xsave, .flags = flags.items });
        mod.addCSourceFiles(.{ .root = root, .files = &x86_sse41, .flags = withDefine(b, flags.items, "-DUSE_SSE41") });
        mod.addCSourceFiles(.{ .root = root, .files = &x86_sse42, .flags = withDefine(b, flags.items, "-DUSE_SSE42") });
    }
    if (arm) {
        mod.addCSourceFiles(.{ .root = root, .files = &arm_common, .flags = flags.items });
        mod.addCSourceFiles(.{ .root = root, .files = &arm_neon, .flags = withDefine(b, flags.items, "-DUSE_NEON") });
        c.addSources(mod, "vvenc_sve", .{
            .module = .{ .cpp = true, .aarch64_features = &.{ .v8_2a, .sve } },
            .setup = setup,
            .groups = &.{.{ .root = root, .files = &arm_sve, .flags = withDefine(b, withDefine(b, flags.items, "-DUSE_NEON"), "-DUSE_SVE") }},
        });
    }

    const lib = c.staticLibrary("vvenc", mod);
    for ([_][]const u8{ "vvencCfg.h", "vvencDecl.h" }) |h| lib.installHeader(src.path(b.fmt("include/vvenc/{s}", .{h})), b.fmt("vvenc/{s}", .{h}));
    lib.installConfigHeader(api);
    lib.installConfigHeader(version);
    return c.single(lib);
}

fn withDefine(b: *std.Build, base: []const []const u8, define: ?[]const u8) []const []const u8 {
    const d = define orelse return base;
    return std.mem.concat(b.allocator, []const u8, &.{ base, &.{d} }) catch @panic("OOM");
}

const common = [_][]const u8{
    "vvenc/vvenc.cpp",
    "vvenc/vvencCfg.cpp",
    "vvenc/vvencimpl.cpp",
    "CommonLib/AdaptiveLoopFilter.cpp",
    "CommonLib/AffineGradientSearch.cpp",
    "CommonLib/BitStream.cpp",
    "CommonLib/Buffer.cpp",
    "CommonLib/CodingStructure.cpp",
    "CommonLib/ContextModelling.cpp",
    "CommonLib/Contexts.cpp",
    "CommonLib/DepQuant.cpp",
    "CommonLib/InterPrediction.cpp",
    "CommonLib/InterpolationFilter.cpp",
    "CommonLib/IntraPrediction.cpp",
    "CommonLib/MCTF.cpp",
    "CommonLib/MatrixIntraPrediction.cpp",
    "CommonLib/Mv.cpp",
    "CommonLib/PicYuvMD5.cpp",
    "CommonLib/Picture.cpp",
    "CommonLib/ProfileLevelTier.cpp",
    "CommonLib/Quant.cpp",
    "CommonLib/QuantRDOQ.cpp",
    "CommonLib/RdCost.cpp",
    "CommonLib/Reshape.cpp",
    "CommonLib/Rom.cpp",
    "CommonLib/RomTr.cpp",
    "CommonLib/SEI.cpp",
    "CommonLib/SampleAdaptiveOffset.cpp",
    "CommonLib/SearchSpaceCounter.cpp",
    "CommonLib/Slice.cpp",
    "CommonLib/StatCounter.cpp",
    "CommonLib/TimeProfiler.cpp",
    "CommonLib/TrQuant.cpp",
    "CommonLib/TrQuant_EMT.cpp",
    "CommonLib/Unit.cpp",
    "CommonLib/UnitPartitioner.cpp",
    "CommonLib/UnitTools.cpp",
    "CommonLib/dtrace.cpp",
    "Utilities/NoMallocThreadPool.cpp",
    "DecoderLib/DecCu.cpp",
    "EncoderLib/BinEncoder.cpp",
    "EncoderLib/BitAllocation.cpp",
    "EncoderLib/CABACWriter.cpp",
    "EncoderLib/EncCfg.cpp",
    "EncoderLib/EncCu.cpp",
    "EncoderLib/EncGOP.cpp",
    "EncoderLib/EncHRD.cpp",
    "EncoderLib/EncLib.cpp",
    "EncoderLib/EncModeCtrl.cpp",
    "EncoderLib/EncPicture.cpp",
    "EncoderLib/EncReshape.cpp",
    "EncoderLib/EncSampleAdaptiveOffset.cpp",
    "EncoderLib/EncSlice.cpp",
    "EncoderLib/GOPCfg.cpp",
    "EncoderLib/InterSearch.cpp",
    "EncoderLib/IntraSearch.cpp",
    "EncoderLib/NALwrite.cpp",
    "EncoderLib/PreProcess.cpp",
    "EncoderLib/RateCtrl.cpp",
    "EncoderLib/SEIEncoder.cpp",
    "EncoderLib/SEIFilmGrainAnalyzer.cpp",
    "EncoderLib/SEIwrite.cpp",
    "EncoderLib/VLCWriter.cpp",
};

const common_sse41 = [_][]const u8{
    "CommonLib/LoopFilter.cpp",
    "CommonLib/QuantRDOQ2.cpp",
    "EncoderLib/EncAdaptiveLoopFilter.cpp",
};

const x86_xsave = [_][]const u8{
    "CommonLib/x86/CommonDefX86.cpp",
    "CommonLib/x86/InitX86.cpp",
};

const x86_sse41 = [_][]const u8{
    "CommonLib/x86/sse41/AdaptiveLoopFilter_sse41.cpp",
    "CommonLib/x86/sse41/AffineGradientSearch_sse41.cpp",
    "CommonLib/x86/sse41/Buffer_sse41.cpp",
    "CommonLib/x86/sse41/DepQuant_sse41.cpp",
    "CommonLib/x86/sse41/FGA_sse41.cpp",
    "CommonLib/x86/sse41/InterPred_sse41.cpp",
    "CommonLib/x86/sse41/InterpolationFilter_sse41.cpp",
    "CommonLib/x86/sse41/IntraPred_sse41.cpp",
    "CommonLib/x86/sse41/LoopFilter_sse41.cpp",
    "CommonLib/x86/sse41/MCTF_avx41.cpp",
    "CommonLib/x86/sse41/Quant_sse41.cpp",
    "CommonLib/x86/sse41/RdCost_sse41.cpp",
    "CommonLib/x86/sse41/SampleAdaptiveOffset_sse41.cpp",
    "CommonLib/x86/sse41/Trafo_sse41.cpp",
};

const x86_sse42 = [_][]const u8{
    "CommonLib/x86/sse42/DepQuant_sse42.cpp",
};

const x86_avx2 = [_][]const u8{
    "CommonLib/x86/avx2/AdaptiveLoopFilter_avx2.cpp",
    "CommonLib/x86/avx2/AffineGradientSearch_avx2.cpp",
    "CommonLib/x86/avx2/Buffer_avx2.cpp",
    "CommonLib/x86/avx2/DepQuant_avx2.cpp",
    "CommonLib/x86/avx2/FGA_avx2.cpp",
    "CommonLib/x86/avx2/InterPred_avx2.cpp",
    "CommonLib/x86/avx2/InterpolationFilter_avx2.cpp",
    "CommonLib/x86/avx2/IntraPred_avx2.cpp",
    "CommonLib/x86/avx2/LoopFilter_avx2.cpp",
    "CommonLib/x86/avx2/MCTF_avx2.cpp",
    "CommonLib/x86/avx2/Quant_avx2.cpp",
    "CommonLib/x86/avx2/RdCost_avx2.cpp",
    "CommonLib/x86/avx2/SampleAdaptiveOffset_avx2.cpp",
    "CommonLib/x86/avx2/Trafo_avx2.cpp",
};

const arm_common = [_][]const u8{
    "CommonLib/arm/CommonDefARM.cpp",
    "CommonLib/arm/InitARM.cpp",
};

const arm_neon = [_][]const u8{
    "CommonLib/arm/neon/AdaptiveLoopFilter_neon.cpp",
    "CommonLib/arm/neon/AffineGradientSearch_neon.cpp",
    "CommonLib/arm/neon/Buffer_neon.cpp",
    "CommonLib/arm/neon/InterPredARM.cpp",
    "CommonLib/arm/neon/InterpolationFilter_neon.cpp",
    "CommonLib/arm/neon/IntraPred_neon.cpp",
    "CommonLib/arm/neon/MCTF_neon.cpp",
    "CommonLib/arm/neon/RdCost_neon.cpp",
    "CommonLib/arm/neon/Trafo_neon.cpp",
};

const arm_sve = [_][]const u8{
    "CommonLib/arm/sve/InterpolationFilter_sve.cpp",
    "CommonLib/arm/sve/MCTF_sve.cpp",
    "CommonLib/arm/sve/RdCost_sve.cpp",
    "CommonLib/arm/sve/Trafo_sve.cpp",
};
