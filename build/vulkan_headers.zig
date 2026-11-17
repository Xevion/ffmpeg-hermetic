//! Khronos Vulkan headers, installed like `cmake --install`. FFmpeg loads the loader at run time,
//! so there is no archive.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const src = c.upstream("vulkan_headers");
    return c.headerOnly(&.{
        .{ "vulkan", src.path("include/vulkan") },
        .{ "vk_video", src.path("include/vk_video") },
    });
}
