//! Khronos OpenCL headers, installed like `cmake --install`. The empty archive only carries the
//! include directory to dependents.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

pub fn build(c: Ctx, _: Nasm) *std.Build.Step.Compile {
    const src = c.upstream("opencl_headers");
    const empty = c.b.addWriteFiles().add("opencl_headers.c", "");
    const mod = c.module(.{});
    mod.addCSourceFile(.{ .file = empty });
    const lib = c.staticLibrary("opencl_headers", mod);
    lib.installHeadersDirectory(src.path("CL"), "CL", .{});
    return lib;
}
