//! Khronos Vulkan headers, installed like `cmake --install`. FFmpeg loads the loader at run time,
//! so there is no archive.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "vulkan_headers",
    .version = "1.4.368",
    .licenses = &.{"LICENSE.md"},
    .ffmpeg = &.{"vulkan"},
};

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const src = c.upstream("vulkan_headers");
    return c.headerOnly(&.{
        .{ "vulkan", src.path("include/vulkan") },
        .{ "vk_video", src.path("include/vk_video") },
    });
}
