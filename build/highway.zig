const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// Targets libjxl's build turns off. Highway and every user of its dispatch tables must agree on it.
pub fn disabledTargets(c: Ctx) []const u8 {
    return switch (c.arch()) {
        .aarch64 => "-DHWY_DISABLED_TARGETS=(HWY_AVX3|HWY_AVX3_SPR|HWY_AVX3_ZEN4|HWY_RVV|HWY_SSSE3|HWY_SVE_256)",
        else => "-DHWY_DISABLED_TARGETS=(HWY_AVX3|HWY_AVX3_SPR|HWY_AVX3_ZEN4|HWY_RVV|HWY_SSSE3|HWY_SVE|HWY_SVE_256|HWY_SVE2|HWY_SVE2_128)",
    };
}

/// Highway's core library without contrib. Its x86 and Arm targets are chosen at runtime.
pub fn build(c: Ctx, _: Nasm) *std.Build.Step.Compile {
    const src = c.upstream("highway");

    const mod = c.module(.{ .cpp = true });
    mod.addIncludePath(src.path(""));
    mod.addCSourceFiles(.{
        .root = src.path("hwy"),
        .files = &sources,
        .flags = &.{
            "-std=c++17",       "-fno-rtti",          "-fno-exceptions",       "-fmath-errno",
            "-fno-vectorize",   "-fno-slp-vectorize", "-fmerge-all-constants", "-DHWY_STATIC_DEFINE",
            disabledTargets(c),
        },
    });

    const lib = c.staticLibrary("hwy", mod);
    for (headers) |h| lib.installHeader(src.path(c.b.fmt("hwy/{s}", .{h})), c.b.fmt("hwy/{s}", .{h}));
    return lib;
}

const sources = [_][]const u8{
    "abort.cc", "aligned_allocator.cc", "nanobenchmark.cc", "per_target.cc", "perf_counters.cc",
    "print.cc", "profiler.cc",          "targets.cc",       "timer.cc",
};

const headers = [_][]const u8{
    "abort.h",           "aligned_allocator.h",     "auto_tune.h",              "base.h",             "bit_set.h",
    "cache_control.h",   "detect_compiler_arch.h",  "detect_targets.h",         "foreach_target.h",   "highway_export.h",
    "highway.h",         "nanobenchmark.h",         "per_target.h",             "print-inl.h",        "print.h",
    "profiler.h",        "robust_statistics.h",     "targets.h",                "timer-inl.h",        "timer.h",
    "x86_cpuid.h",       "ops/arm_neon-inl.h",      "ops/arm_sve-inl.h",        "ops/emu128-inl.h",   "ops/generic_ops-inl.h",
    "ops/inside-inl.h",  "ops/loongarch_lsx-inl.h", "ops/loongarch_lasx-inl.h", "ops/ppc_vsx-inl.h",  "ops/rvv-inl.h",
    "ops/scalar-inl.h",  "ops/set_macros-inl.h",    "ops/shared-inl.h",         "ops/wasm_128-inl.h", "ops/x86_128-inl.h",
    "ops/x86_256-inl.h", "ops/x86_512-inl.h",       "ops/x86_avx3-inl.h",
};
