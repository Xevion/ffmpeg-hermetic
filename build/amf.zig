//! AMD AMF headers, installed under `AMF/` as FFmpeg includes them. FFmpeg loads the AMF runtime
//! at run time, so the empty archive only carries the include directory to dependents.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

pub fn build(c: Ctx, _: Nasm) *std.Build.Step.Compile {
    const src = c.upstream("amf");
    const empty = c.b.addWriteFiles().add("amf_headers.c", "");
    const mod = c.module(.{});
    mod.addCSourceFile(.{ .file = empty });
    const lib = c.staticLibrary("amf_headers", mod);
    lib.installHeadersDirectory(src.path("AMF"), "AMF", .{});
    return lib;
}
