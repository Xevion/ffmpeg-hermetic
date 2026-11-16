const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// libvorbis, libvorbisenc and libvorbisfile, in that order.
pub fn build(c: Ctx, _: Nasm) []const *std.Build.Step.Compile {
    const src = c.upstream("libvorbis");
    const ogg = c.dep("libogg");
    const archives = [_]struct { name: []const u8, files: []const []const u8 }{
        .{ .name = "vorbis", .files = &core },
        .{ .name = "vorbisenc", .files = &.{"vorbisenc.c"} },
        .{ .name = "vorbisfile", .files = &.{"vorbisfile.c"} },
    };
    var out: [archives.len]*std.Build.Step.Compile = undefined;
    for (archives, 0..) |a, i| {
        const mod = c.module(.{});
        mod.addIncludePath(src.path("include"));
        mod.addIncludePath(src.path("lib"));
        mod.addIncludePath(ogg.getEmittedIncludeTree());
        mod.addCSourceFiles(.{
            .root = src.path("lib"),
            .files = a.files,
            .flags = &.{ "-D_REENTRANT", "-fno-common" },
        });
        const lib = c.staticLibrary(a.name, mod);
        for ([_][]const u8{ "codec.h", "vorbisenc.h", "vorbisfile.h" }) |h| {
            if (i == 0) lib.installHeader(src.path("include/vorbis").path(c.b, h), c.b.fmt("vorbis/{s}", .{h}));
        }
        out[i] = lib;
    }
    return c.b.allocator.dupe(*std.Build.Step.Compile, &out) catch @panic("OOM");
}

const core = [_][]const u8{
    "mdct.c",     "smallft.c",   "block.c",    "envelope.c",   "window.c", "lsp.c",     "lpc.c",
    "analysis.c", "synthesis.c", "psy.c",      "info.c",       "floor1.c", "floor0.c",  "res0.c",
    "mapping0.c", "registry.c",  "codebook.c", "sharedbook.c", "lookup.c", "bitrate.c",
};
