const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// libvorbis, libvorbisenc and libvorbisfile; FFmpeg links no libvorbisfile.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const src = c.upstream("libvorbis");
    const ogg = c.dep("libogg");
    const archives = [_]struct { name: []const u8, files: []const []const u8, links: []const []const u8 = &.{"vorbis"}, bundled: bool = true }{
        .{ .name = "vorbis", .files = &core, .links = &.{} },
        .{ .name = "vorbisenc", .files = &.{"vorbisenc.c"} },
        .{ .name = "vorbisfile", .files = &.{"vorbisfile.c"}, .bundled = false },
    };
    var out: [archives.len]Ctx.Archive = undefined;
    for (archives, 0..) |a, i| {
        const mod = c.module(.{});
        mod.addIncludePath(src.path("include"));
        mod.addIncludePath(src.path("lib"));
        mod.addIncludePath(ogg.include);
        mod.addCSourceFiles(.{
            .root = src.path("lib"),
            .files = a.files,
            .flags = &.{ "-D_REENTRANT", "-fno-common" },
        });
        const lib = c.staticLibrary(a.name, mod);
        for ([_][]const u8{ "codec.h", "vorbisenc.h", "vorbisfile.h" }) |h| {
            if (i == 0) lib.installHeader(src.path("include/vorbis").path(c.b, h), c.b.fmt("vorbis/{s}", .{h}));
        }
        out[i] = .{ .lib = lib, .links = a.links, .bundled = a.bundled };
    }
    return c.package(&out);
}

const core = [_][]const u8{
    "mdct.c",     "smallft.c",   "block.c",    "envelope.c",   "window.c", "lsp.c",     "lpc.c",
    "analysis.c", "synthesis.c", "psy.c",      "info.c",       "floor1.c", "floor0.c",  "res0.c",
    "mapping0.c", "registry.c",  "codebook.c", "sharedbook.c", "lookup.c", "bitrate.c",
};
