const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// The GSM 06.10 full-rate codec, with the WAV49 frame packing option.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const src = c.upstream("libgsm");

    const mod = c.module(.{});
    mod.addIncludePath(src.path("inc"));
    mod.addCSourceFiles(.{
        .root = src.path("src"),
        .files = &sources,
        .flags = &.{ "-ansi", "-DNeedFunctionPrototypes=1", "-DSASR", "-DWAV49", "-Wno-comment" },
    });

    const lib = c.staticLibrary("gsm", mod);
    lib.installHeader(src.path("inc/gsm.h"), "gsm.h");
    return c.single(lib);
}

const sources = [_][]const u8{
    "add.c",         "code.c",       "debug.c",       "decode.c",     "long_term.c",  "lpc.c",
    "preprocess.c",  "rpe.c",        "gsm_destroy.c", "gsm_decode.c", "gsm_encode.c", "gsm_explode.c",
    "gsm_implode.c", "gsm_create.c", "gsm_print.c",   "gsm_option.c", "short_term.c", "table.c",
};
