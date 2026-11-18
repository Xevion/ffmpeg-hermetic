const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "libtheora",
    .version = "1.2.0",
    .licenses = &.{ "COPYING", "LICENSE" },
    .spdx = "BSD-3-Clause",
    .needs = &.{"libogg"},
    .ffmpeg = &.{"libtheora"},
};

/// libtheoradec and libtheoraenc. The x86 paths are inline assembly with cpuid dispatch, so
/// they need no extra target features.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const b = c.b;
    const src = c.upstream("libtheora");
    const ogg = c.dep("libogg");
    // Upstream ships MSVC-syntax inline asm for 32-bit x86 only, so x86_64 msvc builds C only.
    const x86 = c.arch() == .x86_64 and !c.isMsvc();

    const archives = [_]struct { name: []const u8, groups: []const []const []const u8, links: []const []const u8 = &.{} }{
        .{ .name = "theoradec", .groups = &.{ &common, &decoder } },
        .{ .name = "theoraenc", .groups = &.{ &common, &encoder }, .links = &.{"theoradec"} },
    };
    var out: [archives.len]Ctx.Archive = undefined;
    for (archives, 0..) |a, i| {
        const mod = c.module(.{});
        mod.addIncludePath(src.path("include"));
        mod.addIncludePath(src.path("lib"));
        mod.addIncludePath(ogg.include);
        var flags: std.ArrayList([]const u8) = .empty;
        flags.append(b.allocator, "-fvisibility=hidden") catch @panic("OOM");
        if (x86) flags.appendSlice(b.allocator, &.{ "-DOC_X86_ASM", "-DOC_X86_64_ASM" }) catch @panic("OOM");
        for (a.groups) |files| mod.addCSourceFiles(.{ .root = src.path("lib"), .files = files, .flags = flags.items });
        if (x86) {
            const arch_files: []const []const u8 = if (i == 0) &x86_decoder else &x86_encoder;
            mod.addCSourceFiles(.{ .root = src.path("lib"), .files = arch_files, .flags = flags.items });
        }
        const lib = c.staticLibrary(a.name, mod);
        if (i == 0) {
            for ([_][]const u8{ "theora.h", "theoradec.h", "theoraenc.h", "codec.h" }) |h| {
                lib.installHeader(src.path(b.fmt("include/theora/{s}", .{h})), b.fmt("theora/{s}", .{h}));
            }
        }
        out[i] = .{ .lib = lib, .links = a.links };
    }
    return c.package(&out);
}

const common = [_][]const u8{
    "apiwrapper.c", "bitpack.c", "dequant.c", "fragment.c", "idct.c", "info.c", "internal.c", "quant.c", "state.c",
};

const decoder = [_][]const u8{ "decapiwrapper.c", "decinfo.c", "decode.c", "huffdec.c" };

const encoder = [_][]const u8{
    "analyze.c", "fdct.c",    "encfrag.c", "encapiwrapper.c", "encinfo.c", "encode.c",
    "enquant.c", "huffenc.c", "mathops.c", "mcenc.c",         "rate.c",    "tokenize.c",
};

const x86_decoder = [_][]const u8{
    "x86/x86cpu.c", "x86/mmxidct.c", "x86/mmxfrag.c", "x86/mmxstate.c", "x86/sse2idct.c", "x86/x86state.c",
};

const x86_encoder = x86_decoder ++ [_][]const u8{
    "x86/mmxencfrag.c", "x86/mmxfdct.c", "x86/sse2encfrag.c", "x86/x86enquant.c", "x86/x86enc.c", "x86/sse2fdct.c",
};
