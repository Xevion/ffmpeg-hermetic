const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const src = c.upstream("bzip2");
    const mod = c.module(.{});
    mod.addCSourceFiles(.{
        .root = src.path(""),
        .files = &.{ "blocksort.c", "huffman.c", "crctable.c", "randtable.c", "compress.c", "decompress.c", "bzlib.c" },
        .flags = &.{"-D_FILE_OFFSET_BITS=64"},
    });
    const lib = c.staticLibrary("bz2", mod);
    lib.installHeader(src.path("bzlib.h"), "bzlib.h");
    return c.single(lib);
}
