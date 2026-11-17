//! AMD AMF headers, installed under `AMF/` as FFmpeg includes them. FFmpeg loads the AMF runtime
//! at run time, so there is no archive.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    return c.headerOnly(&.{.{ "AMF", c.upstream("amf").path("AMF") }});
}
