const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// libvmaf with the integer and float feature extractors and the built-in models. The x86
/// kernels (AVX2, AVX-512) and the NEON ones are chosen at runtime.
pub fn build(c: Ctx, nasm: Nasm) ?Ctx.Output {
    const b = c.b;
    const src = c.upstream("libvmaf");
    const t = c.target.result;
    const x86 = c.arch() == .x86_64;
    const arm = c.arch() == .aarch64;
    const prefix = t.os.tag.isDarwin();

    const config = b.addConfigHeader(.{ .style = .blank, .include_path = "config.h" }, .{
        .PREFIX = if (prefix) @as(?i64, 1) else null,
        .HAVE_ASM = if (x86 or arm) @as(?i64, 1) else null,
        .ARCH_AARCH64 = if (arm) @as(?i64, 1) else null,
        .ARCH_ARM = if (arm) @as(?i64, 0) else null,
        .ARCH_X86 = if (x86) @as(?i64, 1) else null,
        .ARCH_X86_64 = if (x86) @as(?i64, 1) else null,
        .ARCH_X86_32 = if (x86) @as(?i64, 0) else null,
        .HAVE_AVX512 = if (x86) @as(?i64, 1) else null,
        .VMAF_FLOAT_FEATURES = 1,
        .VMAF_BUILT_IN_MODELS = 1,
    });
    const generated = b.addWriteFiles();
    _ = generated.add("vcs_version.h", "#define VMAF_VERSION \"3.2.0\"\n");
    const version = b.addConfigHeader(.{
        .style = .{ .cmake = src.path("libvmaf/include/libvmaf/version.h.in") },
        .include_path = "libvmaf/version.h",
    }, .{ .VMAF_API_VERSION_MAJOR = 3, .VMAF_API_VERSION_MINOR = 2, .VMAF_API_VERSION_PATCH = 0 });
    if (x86) _ = generated.add("config.asm", b.fmt(
        \\%define ARCH_X86_64 1
        \\%define ARCH_X86_32 0
        \\%define PIC 1
        \\%define HAVE_AVX512 1
        \\{s}
    , .{if (prefix) "%define PREFIX 1\n" else ""}));

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{ "-pedantic", "-DOC_NEW_STYLE_INCLUDES" }) catch @panic("OOM");
    if (t.os.tag == .linux or c.isWindows()) flags.append(b.allocator, "-D_GNU_SOURCE") catch @panic("OOM");
    if (prefix) flags.append(b.allocator, "-D_DARWIN_C_SOURCE") catch @panic("OOM");
    const c_flags = std.mem.concat(b.allocator, []const u8, &.{ flags.items, &.{"-std=c11"} }) catch @panic("OOM");
    const cpp_flags = std.mem.concat(b.allocator, []const u8, &.{ flags.items, &.{ "-std=c++11", "-U_LIBCPP_ENABLE_ASSERTIONS" } }) catch @panic("OOM");

    const setup: Ctx.Setup = .{
        .config_headers = &.{ config, version },
        .includes = std.mem.concat(b.allocator, std.Build.LazyPath, &.{
            &.{generated.getDirectory()},
            c.includeDirs(src.path("libvmaf"), &.{ "src", "src/feature", "src/feature/common", "src/feature/cuda", "include", "include/libvmaf" }),
        }) catch @panic("OOM"),
    };
    const root = src.path("libvmaf/src");

    const mod = c.module(.{});
    setup.apply(mod);
    mod.addCSourceFiles(.{ .root = root, .files = &(core ++ feature ++ feature_float), .flags = c_flags });
    mod.addCSourceFiles(.{ .root = root, .files = &.{"cpu.c"}, .flags = c_flags });

    c.addSources(mod, "vmaf_svm", .{
        .module = .{ .cpp = true },
        .setup = setup,
        .groups = &.{.{ .root = root, .files = &.{"svm.cpp"}, .flags = cpp_flags }},
    });

    if (x86) {
        mod.addCSourceFiles(.{ .root = root, .files = &.{"x86/cpu.c"}, .flags = c_flags });
        nasm.addFiles(c, mod, .{
            .root = root,
            .files = &.{"x86/cpuid.asm"},
            .include_dirs = &.{ root, generated.getDirectory() },
        });
        const isas = [_]struct { name: []const u8, features: []const std.Target.x86.Feature, files: []const []const u8 }{
            .{ .name = "vmaf_avx2", .features = &.{ .avx, .avx2, .fma }, .files = &avx2 },
            .{ .name = "vmaf_avx512", .features = &.{ .avx512f, .avx512dq, .avx512bw, .avx512cd, .avx512vl }, .files = &avx512 },
        };
        for (isas) |isa| {
            c.addSources(mod, isa.name, .{
                .module = .{ .x86_features = isa.features },
                .setup = setup,
                .groups = &.{.{ .root = root, .files = isa.files, .flags = c_flags }},
            });
        }
    }
    if (arm) {
        mod.addCSourceFiles(.{ .root = root, .files = &.{"arm/cpu.c"}, .flags = c_flags });
        mod.addCSourceFiles(.{
            .root = root,
            .files = &.{ "feature/arm64/vif_neon.c", "feature/arm64/adm_neon.c", "feature/arm64/motion_neon.c" },
            .flags = std.mem.concat(b.allocator, []const u8, &.{ c_flags, &.{"-DARCH_AARCH64"} }) catch @panic("OOM"),
        });
    }

    const xxd = b.addExecutable(.{
        .name = "xxd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/libvmaf/xxd.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
    for (models) |model| {
        const run = b.addRunArtifact(xxd);
        run.addFileArg2(src.path(b.fmt("model/{s}", .{model})), .{});
        const stem = std.fs.path.basename(model);
        const symbol = b.fmt("src_{s}", .{stem});
        for (symbol) |*ch| if (!std.ascii.isAlphanumeric(ch.*)) {
            ch.* = '_';
        };
        const out = run.addOutputFileArg2(b.fmt("{s}.c", .{stem}), .{});
        run.addArg(symbol);
        mod.addCSourceFile(.{ .file = out });
    }

    const lib = c.staticLibrary("vmaf", mod);
    for ([_][]const u8{ "libvmaf.h", "feature.h", "model.h", "picture.h" }) |h| {
        lib.installHeader(src.path(b.fmt("libvmaf/include/libvmaf/{s}", .{h})), b.fmt("libvmaf/{s}", .{h}));
    }
    lib.installConfigHeader(version);
    return c.single(lib);
}

const core = [_][]const u8{
    "libvmaf.c",        "predict.c",     "model.c",     "picture.c",          "mem.c",          "output.c",
    "fex_ctx_vector.c", "thread_pool.c", "dict.c",      "opt.c",              "ref.c",          "read_json_model.c",
    "pdjson.c",         "log.c",         "framesync.c", "metadata_handler.c", "picture_pool.c",
};

const feature = [_][]const u8{
    "feature/picture_copy.c",       "feature/integer_psnr.c",      "feature/third_party/xiph/psnr_hvs.c",
    "feature/feature_extractor.c",  "feature/feature_name.c",      "feature/alias.c",
    "feature/integer_adm.c",        "feature/feature_collector.c", "feature/integer_motion.c",
    "feature/integer_vif.c",        "feature/ciede.c",             "feature/common/alignment.c",
    "feature/mkdirp.c",             "feature/float_ssim.c",        "feature/float_ms_ssim.c",
    "feature/ssim.c",               "feature/ms_ssim.c",           "feature/iqa/decimate.c",
    "feature/iqa/ssim_tools.c",     "feature/iqa/math_utils.c",    "feature/iqa/convolve.c",
    "feature/cambi.c",              "feature/luminance_tools.c",   "feature/null.c",
    "feature/common/convolution.c", "feature/vif_tools.c",         "feature/speed.c",
};

const feature_float = [_][]const u8{
    "feature/float_adm.c",         "feature/float_psnr.c",   "feature/float_ansnr.c", "feature/float_motion.c",
    "feature/float_vif.c",         "feature/float_moment.c", "feature/offset.c",      "feature/adm.c",
    "feature/adm_tools.c",         "feature/ansnr.c",        "feature/ansnr_tools.c", "feature/vif.c",
    "feature/motion.c",            "feature/psnr.c",         "feature/psnr_tools.c",  "feature/moment.c",
    "feature/common/blur_array.c",
};

const avx2 = [_][]const u8{
    "feature/common/convolution_avx.c", "feature/x86/motion_avx2.c", "feature/x86/vif_avx2.c",
    "feature/x86/adm_avx2.c",           "feature/x86/cambi_avx2.c",  "feature/x86/speed_avx2.c",
};

const avx512 = [_][]const u8{
    "feature/x86/motion_avx512.c", "feature/x86/vif_avx512.c", "feature/x86/adm_avx512.c", "feature/x86/speed_avx512.c",
};

const models = [_][]const u8{
    "vmaf_v0.6.1.json",
    "vmaf_b_v0.6.3.json",
    "vmaf_v0.6.1neg.json",
    "vmaf_4k_v0.6.1.json",
    "vmaf_4k_v0.6.1neg.json",
    "vmaf_float_v0.6.1neg.json",
    "vmaf_float_v0.6.1.json",
    "vmaf_float_b_v0.6.3.json",
    "vmaf_float_4k_v0.6.1.json",
    "vmaf_v1.0.16/vmaf_v1.0.16_3d0h.json",
    "vmaf_v1.0.16/vmaf_v1.0.16_3d0h_2160.json",
    "vmaf_v1.0.16/vmaf_v1.0.16_5d0h.json",
    "vmaf_v1.0.16/vmaf_v1.0.16_1d5h_2160.json",
    "vmaf_v1.0.16_hfr/vmaf_v1.0.16_hfr_3d0h.json",
    "vmaf_v1.0.16_hfr/vmaf_v1.0.16_hfr_3d0h_2160.json",
    "vmaf_v1.0.16_hfr/vmaf_v1.0.16_hfr_5d0h.json",
    "vmaf_v1.0.16_hfr/vmaf_v1.0.16_hfr_1d5h_2160.json",
};
