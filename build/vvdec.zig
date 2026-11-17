const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// VVdeC, the H.266/VVC decoder (C++). Upstream builds every x86 file with SSE4.1, so the
/// baseline is SSE4.1 and AVX2 is chosen at runtime. Other architectures run the x86 kernels through SIMDe.
pub fn build(c: Ctx, _: Nasm) *std.Build.Step.Compile {
    const b = c.b;
    const src = c.upstream("vvdec");
    const x86 = c.arch() == .x86_64;
    const arm = c.arch() == .aarch64;

    const version = b.addConfigHeader(.{
        .style = .{ .cmake = src.path("source/Lib/vvdec/version.h.in") },
        .include_path = "vvdec/version.h",
    }, .{ .PROJECT_VERSION_MAJOR = 3, .PROJECT_VERSION_MINOR = 2, .PROJECT_VERSION_PATCH = 1 });
    const api = b.addConfigHeader(.{
        .style = .{ .cmake = src.path("include/vvdec/vvdec.h.in") },
        .include_path = "vvdec/vvdec.h",
    }, .{ .VVDEC_USE_UNSTABLE_API = 0 });

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{
        "-std=c++14",     "-fvisibility=hidden", "-fvisibility-inlines-hidden",
        "-DVVDEC_SOURCE", "-DTARGET_SIMD_X86=1",
    }) catch @panic("OOM");
    if (c.isWindows()) flags.append(b.allocator, "-D_WIN32_WINNT=0x0600") catch @panic("OOM");
    if (arm) flags.appendSlice(b.allocator, &.{
        "-DTARGET_SIMD_ARM=1",      "-DTARGET_SIMD_ARM_RDM=1",     "-DTARGET_SIMD_ARM_SVE=1",
        "-DTARGET_SIMD_ARM_SVE2=1", "-fno-lax-vector-conversions",
    }) catch @panic("OOM");

    const setup: Ctx.Setup = .{
        .config_headers = &.{ version, api },
        .includes = std.mem.concat(b.allocator, std.Build.LazyPath, &.{
            &.{ src.path("include"), src.path("source/Lib") },
            c.includeDirs(src.path("source/Lib"), &.{ "vvdec", "DecoderLib", "CommonLib", "CommonLib/x86", "CommonLib/arm", "libmd5" }),
            &.{src.path("thirdparty")},
        }) catch @panic("OOM"),
    };
    const root = src.path("source/Lib");

    const baseline: []const std.Target.x86.Feature = if (x86) &.{.sse4_1} else &.{};
    const mod = c.module(.{ .cpp = true, .x86_features = baseline });
    setup.apply(mod);
    mod.addCSourceFiles(.{ .root = root, .files = &common, .flags = flags.items });

    if (x86) {
        const isas = [_]struct { name: []const u8, define: ?[]const u8 = null, features: []const std.Target.x86.Feature, files: []const []const u8 }{
            .{ .name = "vvdec_x86", .features = &.{ .sse4_1, .xsave }, .files = &x86_xsave },
            .{ .name = "vvdec_sse41", .define = "-DUSE_SSE41", .features = &.{.sse4_1}, .files = &x86_sse41 },
            .{ .name = "vvdec_avx2", .define = "-DUSE_AVX2", .features = &.{ .sse4_1, .avx2 }, .files = &x86_avx2 },
        };
        for (isas) |isa| {
            c.addSources(mod, isa.name, .{
                .module = .{ .cpp = true, .x86_features = isa.features },
                .setup = setup,
                .groups = &.{.{ .root = root, .files = isa.files, .flags = withDefine(b, flags.items, isa.define) }},
            });
        }
    } else {
        mod.addCSourceFiles(.{ .root = root, .files = &x86_sse41, .flags = withDefine(b, flags.items, "-DUSE_SSE41") });
    }
    if (arm) {
        const neon = withDefine(b, flags.items, "-DUSE_NEON");
        mod.addCSourceFiles(.{ .root = root, .files = &arm_common, .flags = flags.items });
        mod.addCSourceFiles(.{ .root = root, .files = &arm_neon, .flags = neon });
        const isas = [_]struct { name: []const u8, features: []const std.Target.aarch64.Feature, defines: []const []const u8, files: []const []const u8 }{
            .{ .name = "vvdec_rdm", .features = &.{.v8_1a}, .defines = &.{"-DUSE_NEON"}, .files = &arm_neon_rdm },
            .{ .name = "vvdec_sve", .features = &.{ .v8_2a, .sve }, .defines = &.{ "-DUSE_NEON", "-DUSE_SVE" }, .files = &arm_sve },
            .{ .name = "vvdec_sve2", .features = &.{ .v9a, .sve2 }, .defines = &.{ "-DUSE_NEON", "-DUSE_SVE", "-DUSE_SVE2" }, .files = &arm_sve2 },
        };
        for (isas) |isa| {
            c.addSources(mod, isa.name, .{
                .module = .{ .cpp = true, .aarch64_features = isa.features },
                .setup = setup,
                .groups = &.{.{ .root = root, .files = isa.files, .flags = std.mem.concat(b.allocator, []const u8, &.{ flags.items, isa.defines }) catch @panic("OOM") }},
            });
        }
    }

    const lib = c.staticLibrary("vvdec", mod);
    for ([_][]const u8{ "sei.h", "vvdecDecl.h" }) |h| lib.installHeader(src.path(b.fmt("include/vvdec/{s}", .{h})), b.fmt("vvdec/{s}", .{h}));
    lib.installConfigHeader(api);
    lib.installConfigHeader(version);
    return lib;
}

fn withDefine(b: *std.Build, base: []const []const u8, define: ?[]const u8) []const []const u8 {
    const d = define orelse return base;
    return std.mem.concat(b.allocator, []const u8, &.{ base, &.{d} }) catch @panic("OOM");
}

const common = [_][]const u8{
    "vvdec/vvdec.cpp",
    "vvdec/vvdecimpl.cpp",
    "vvdec/wasm_bindings.cpp",
    "CommonLib/AdaptiveLoopFilter.cpp",
    "CommonLib/BitStream.cpp",
    "CommonLib/Buffer.cpp",
    "CommonLib/ChromaFormat.cpp",
    "CommonLib/CodingStructure.cpp",
    "CommonLib/ContextModelling.cpp",
    "CommonLib/Contexts.cpp",
    "CommonLib/InterPrediction.cpp",
    "CommonLib/InterpolationFilter.cpp",
    "CommonLib/IntraPrediction.cpp",
    "CommonLib/LoopFilter.cpp",
    "CommonLib/MatrixIntraPrediction.cpp",
    "CommonLib/Mv.cpp",
    "CommonLib/ParameterSetManager.cpp",
    "CommonLib/PicListManager.cpp",
    "CommonLib/PicYuvMD5.cpp",
    "CommonLib/Picture.cpp",
    "CommonLib/Quant.cpp",
    "CommonLib/RdCost.cpp",
    "CommonLib/Reshape.cpp",
    "CommonLib/Rom.cpp",
    "CommonLib/RomLFNST.cpp",
    "CommonLib/RomTr.cpp",
    "CommonLib/SEI_internal.cpp",
    "CommonLib/SampleAdaptiveOffset.cpp",
    "CommonLib/Slice.cpp",
    "CommonLib/StatCounter.cpp",
    "CommonLib/TrQuant.cpp",
    "CommonLib/TrQuant_EMT.cpp",
    "CommonLib/Unit.cpp",
    "CommonLib/UnitPartitioner.cpp",
    "CommonLib/UnitTools.cpp",
    "CommonLib/WeightPrediction.cpp",
    "CommonLib/dtrace.cpp",
    "Utilities/ThreadPool.cpp",
    "DecoderLib/AnnexBread.cpp",
    "DecoderLib/BinDecoder.cpp",
    "DecoderLib/CABACReader.cpp",
    "DecoderLib/DecCu.cpp",
    "DecoderLib/DecLib.cpp",
    "DecoderLib/DecLibParser.cpp",
    "DecoderLib/DecLibRecon.cpp",
    "DecoderLib/DecSlice.cpp",
    "DecoderLib/HLSyntaxReader.cpp",
    "DecoderLib/NALread.cpp",
    "DecoderLib/SEIread.cpp",
    "DecoderLib/VLCReader.cpp",
    "FilmGrain/FilmGrain.cpp",
    "FilmGrain/FilmGrainImpl.cpp",
};

const x86_xsave = [_][]const u8{
    "CommonLib/x86/CommonDefX86.cpp",
    "CommonLib/x86/InitX86.cpp",
};

const x86_sse41 = [_][]const u8{
    "CommonLib/x86/sse41/AdaptiveLoopFilter_sse41.cpp",
    "CommonLib/x86/sse41/Buffer_sse41.cpp",
    "CommonLib/x86/sse41/InterPred_sse41.cpp",
    "CommonLib/x86/sse41/InterpolationFilter_sse41.cpp",
    "CommonLib/x86/sse41/IntraPred_sse41.cpp",
    "CommonLib/x86/sse41/LoopFilter_sse41.cpp",
    "CommonLib/x86/sse41/Picture_sse41.cpp",
    "CommonLib/x86/sse41/Quant_sse41.cpp",
    "CommonLib/x86/sse41/RdCost_sse41.cpp",
    "CommonLib/x86/sse41/SampleAdaptiveOffset_sse41.cpp",
    "CommonLib/x86/sse41/Trafo_sse41.cpp",
    "FilmGrain/FilmGrainImpl_sse41.cpp",
};

const x86_avx2 = [_][]const u8{
    "CommonLib/x86/avx2/AdaptiveLoopFilter_avx2.cpp",
    "CommonLib/x86/avx2/Buffer_avx2.cpp",
    "CommonLib/x86/avx2/InterPred_avx2.cpp",
    "CommonLib/x86/avx2/InterpolationFilter_avx2.cpp",
    "CommonLib/x86/avx2/IntraPred_avx2.cpp",
    "CommonLib/x86/avx2/LoopFilter_avx2.cpp",
    "CommonLib/x86/avx2/Picture_avx2.cpp",
    "CommonLib/x86/avx2/Quant_avx2.cpp",
    "CommonLib/x86/avx2/RdCost_avx2.cpp",
    "CommonLib/x86/avx2/SampleAdaptiveOffset_avx2.cpp",
    "CommonLib/x86/avx2/Trafo_avx2.cpp",
    "FilmGrain/FilmGrainImpl_avx2.cpp",
};

const arm_common = [_][]const u8{
    "CommonLib/arm/CommonDefARM.cpp",
    "CommonLib/arm/InitARM.cpp",
};

const arm_neon = [_][]const u8{
    "CommonLib/arm/neon/AdaptiveLoopFilter_neon.cpp",
    "CommonLib/arm/neon/Buffer_neon.cpp",
    "CommonLib/arm/neon/InterPred_neon.cpp",
    "CommonLib/arm/neon/InterpolationFilter_neon.cpp",
    "CommonLib/arm/neon/IntraPred_neon.cpp",
    "CommonLib/arm/neon/LoopFilter_neon.cpp",
    "CommonLib/arm/neon/Picture_neon.cpp",
    "CommonLib/arm/neon/Quant_neon.cpp",
    "CommonLib/arm/neon/RdCost_neon.cpp",
    "CommonLib/arm/neon/SampleAdaptiveOffset_neon.cpp",
    "CommonLib/arm/neon/Trafo_neon.cpp",
};

const arm_neon_rdm = [_][]const u8{
    "CommonLib/arm/neon_rdm/Buffer_neon_rdm.cpp",
};

const arm_sve = [_][]const u8{
    "CommonLib/arm/sve/Buffer_sve.cpp",
    "CommonLib/arm/sve/InterpolationFilter_sve.cpp",
};

const arm_sve2 = [_][]const u8{
    "CommonLib/arm/sve2/Buffer_sve2.cpp",
};
