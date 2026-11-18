//! Khronos OpenCL ICD loader as a static libOpenCL; it dlopens the vendor drivers at run time.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "opencl",
    .zon = "opencl_icd_loader",
    .version = "2026.05.29",
    .licenses = &.{"LICENSE"},
    .spdx = "Apache-2.0",
    .needs = &.{"opencl_headers"},
    .ffmpeg = &.{"opencl"},
    .system_libs = .{ .linux = &.{ "pthread", "dl" }, .windows = &.{ "cfgmgr32", "ole32", "advapi32" } },
    // macOS has no ICDs to load; its OpenCL is Apple's framework, which FFmpeg includes as <OpenCL/cl.h>.
    .supports = Meta.support.linuxOrWindows,
};

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const b = c.b;
    const src = c.upstream("opencl_icd_loader");
    const windows = c.isWindows();

    const mod = c.module(.{});
    mod.addIncludePath(src.path("loader"));
    mod.addIncludePath(src.path("include"));
    mod.addIncludePath(c.dep("opencl_headers").include);
    if (!windows) {
        const config = b.addConfigHeader(.{
            .style = .{ .cmake = src.path("loader/icd_cmake_config.h.in") },
            .include_path = "icd_cmake_config.h",
        }, .{ .HAVE_SECURE_GETENV = true, .HAVE___SECURE_GETENV = true });
        mod.addConfigHeader(config);
    }
    const flags = [_][]const u8{
        "-DCL_TARGET_OPENCL_VERSION=310",
        "-DCL_NO_NON_ICD_DISPATCH_EXTENSION_PROTOTYPES",
        "-DOPENCL_ICD_LOADER_VERSION_MAJOR=3",
        "-DOPENCL_ICD_LOADER_VERSION_MINOR=1",
        "-DOPENCL_ICD_LOADER_VERSION_REV=0",
        "-DCL_ENABLE_LAYERS",
    };
    mod.addCSourceFiles(.{ .root = src.path("loader"), .files = &common, .flags = &flags });
    mod.addCSourceFiles(.{ .root = src.path("loader"), .files = if (windows) &windows_c else &linux_c, .flags = &flags });

    return c.single(c.staticLibrary("OpenCL", mod));
}

const common = [_][]const u8{ "icd.c", "icd_dispatch.c", "icd_dispatch_generated.c", "icd_trace.c" };

const linux_c = [_][]const u8{ "linux/icd_linux.c", "linux/icd_linux_library.c", "linux/icd_linux_envvars.c" };

const windows_c = [_][]const u8{
    "windows/icd_windows.c",
    "windows/icd_windows_dxgk.c",
    "windows/icd_windows_library.c",
    "windows/icd_windows_envvars.c",
    "windows/icd_windows_hkr.c",
    "windows/icd_windows_apppackage.c",
};
