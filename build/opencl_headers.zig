//! Khronos OpenCL headers, installed like `cmake --install`. There is no archive.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    return c.headerOnly(&.{.{ "CL", c.upstream("opencl_headers").path("CL") }});
}
