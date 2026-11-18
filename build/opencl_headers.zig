//! Khronos OpenCL headers, installed like `cmake --install`. There is no archive.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "opencl_headers",
    .version = "2026.05.29",
    .spdx = "Apache-2.0",
    .licenses = &.{"LICENSE"},
};

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    return c.headerOnly(&.{.{ "CL", c.upstream("opencl_headers").path("CL") }});
}
