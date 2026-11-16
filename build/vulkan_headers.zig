//! Khronos Vulkan headers, installed like `cmake --install`. FFmpeg loads the loader at run time,
//! so the empty archive only carries the include directory to dependents.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

pub fn build(c: Ctx, _: Nasm) *std.Build.Step.Compile {
    const src = c.upstream("vulkan_headers");
    const empty = c.b.addWriteFiles().add("vulkan_headers.c", "");
    const mod = c.module(.{});
    mod.addCSourceFile(.{ .file = empty });
    const lib = c.staticLibrary("vulkan_headers", mod);
    for ([_][]const u8{ "vulkan", "vk_video" }) |dir| {
        lib.installHeadersDirectory(src.path(c.b.fmt("include/{s}", .{dir})), dir, .{});
    }
    return lib;
}
