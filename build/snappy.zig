const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// Snappy (C++) with its C API. Upstream compiles one kernel per target baseline, with no runtime dispatch.
pub fn build(c: Ctx, _: Nasm) *std.Build.Step.Compile {
    const b = c.b;
    const src = c.upstream("snappy");
    const t = c.target.result;
    const posix = !c.isWindows();
    const x86 = c.arch() == .x86_64;
    const arm = c.arch() == .aarch64;

    const config = b.addConfigHeader(.{
        .style = .{ .cmake = src.path("cmake/config.h.in") },
        .include_path = "config.h",
    }, .{
        .HAVE_ATTRIBUTE_ALWAYS_INLINE = true,
        .HAVE_BUILTIN_CTZ = true,
        .HAVE_BUILTIN_EXPECT = true,
        .HAVE_BUILTIN_PREFETCH = true,
        .HAVE_FUNC_MMAP = posix,
        .HAVE_FUNC_SYSCONF = posix,
        .HAVE_LIBLZO2 = false,
        .HAVE_LIBZ = false,
        .HAVE_LIBLZ4 = false,
        .HAVE_SYS_MMAN_H = posix,
        .HAVE_SYS_RESOURCE_H = posix,
        .HAVE_SYS_TIME_H = posix,
        .HAVE_SYS_UIO_H = posix,
        .HAVE_UNISTD_H = posix,
        .HAVE_WINDOWS_H = c.isWindows(),
        .SNAPPY_HAVE_SSSE3 = x86 and std.Target.x86.featureSetHas(t.cpu.features, .ssse3),
        .SNAPPY_HAVE_X86_CRC32 = x86 and std.Target.x86.featureSetHas(t.cpu.features, .sse4_2),
        .SNAPPY_HAVE_BMI2 = x86 and std.Target.x86.featureSetHas(t.cpu.features, .bmi2),
        .SNAPPY_HAVE_NEON = arm and std.Target.aarch64.featureSetHas(t.cpu.features, .neon),
        .SNAPPY_RVV_1 = false,
        .SNAPPY_RVV_0_7 = false,
        .SNAPPY_HAVE_NEON_CRC32 = arm and std.Target.aarch64.featureSetHas(t.cpu.features, .crc),
        .SNAPPY_IS_BIG_ENDIAN = t.cpu.arch.endian() == .big,
    });
    const stubs = b.addConfigHeader(.{
        .style = .{ .cmake = src.path("snappy-stubs-public.h.in") },
        .include_path = "snappy-stubs-public.h",
    }, .{
        .HAVE_SYS_UIO_H_01 = @as(i64, if (posix) 1 else 0),
        .PROJECT_VERSION_MAJOR = 1,
        .PROJECT_VERSION_MINOR = 3,
        .PROJECT_VERSION_PATCH = 1,
    });

    const mod = c.module(.{ .cpp = true });
    mod.addConfigHeader(config);
    mod.addConfigHeader(stubs);
    mod.addIncludePath(src.path(""));
    mod.addCSourceFiles(.{
        .root = src.path(""),
        .files = &.{ "snappy-c.cc", "snappy-sinksource.cc", "snappy-stubs-internal.cc", "snappy.cc" },
        .flags = &.{ if (c.isMsvc()) "-std=c++14" else "-std=c++11", "-fno-exceptions", "-fno-rtti", "-DHAVE_CONFIG_H" },
    });

    const lib = c.staticLibrary("snappy", mod);
    for ([_][]const u8{ "snappy-c.h", "snappy-sinksource.h", "snappy.h" }) |h| lib.installHeader(src.path(h), h);
    lib.installConfigHeader(stubs);
    return lib;
}
