const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// brotlicommon, brotlidec and brotlienc, in that order.
pub fn build(c: Ctx, _: Nasm) []const *std.Build.Step.Compile {
    const src = c.upstream("brotli");
    const archives = [_]struct { name: []const u8, dir: []const u8, files: []const []const u8 }{
        .{ .name = "brotlicommon", .dir = "common", .files = &common },
        .{ .name = "brotlidec", .dir = "dec", .files = &dec },
        .{ .name = "brotlienc", .dir = "enc", .files = &enc },
    };
    var out: [archives.len]*std.Build.Step.Compile = undefined;
    for (archives, 0..) |a, i| {
        const mod = c.module(.{});
        mod.addIncludePath(src.path("c/include"));
        mod.addCSourceFiles(.{ .root = src.path(c.b.fmt("c/{s}", .{a.dir})), .files = a.files });
        const lib = c.staticLibrary(a.name, mod);
        if (i == 0) for (headers) |h| lib.installHeader(src.path(c.b.fmt("c/include/brotli/{s}", .{h})), c.b.fmt("brotli/{s}", .{h}));
        out[i] = lib;
    }
    return c.b.allocator.dupe(*std.Build.Step.Compile, &out) catch @panic("OOM");
}

const headers = [_][]const u8{ "decode.h", "encode.h", "port.h", "shared_dictionary.h", "types.h" };

const common = [_][]const u8{ "constants.c", "context.c", "dictionary.c", "platform.c", "shared_dictionary.c", "transform.c" };

const dec = [_][]const u8{ "bit_reader.c", "decode.c", "huffman.c", "prefix.c", "state.c", "static_init.c" };

const enc = [_][]const u8{
    "backward_references.c", "backward_references_hq.c",     "bit_cost.c",        "block_splitter.c",
    "brotli_bit_stream.c",   "cluster.c",                    "command.c",         "compound_dictionary.c",
    "compress_fragment.c",   "compress_fragment_two_pass.c", "dictionary_hash.c", "encode.c",
    "encoder_dict.c",        "entropy_encode.c",             "fast_log.c",        "histogram.c",
    "literal_cost.c",        "memory.c",                     "metablock.c",       "static_dict.c",
    "static_dict_lut.c",     "static_init.c",                "utf8_util.c",
};
