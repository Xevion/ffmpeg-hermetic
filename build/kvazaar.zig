const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

pub fn build(c: Ctx, _: Nasm) *std.Build.Step.Compile {
    const src = c.upstream("kvazaar");
    const x86 = c.target.result.cpu.arch.isX86();
    const flags = [_][]const u8{ "-DCMAKE_BUILD", "-DKVZ_DLL_EXPORTS", "-DNDEBUG" };

    const generated = c.b.addWriteFiles();
    _ = generated.add("version.h",
        \\#pragma once
        \\#ifndef KVZ_VERSION
        \\#define KVZ_VERSION 2.3.2
        \\#endif
        \\#define KVZ_COMPILER_STRING "clang"
        \\#define KVZ_COMPILE_DATE ""
        \\#define VERSION_STRING QUOTE_EXPAND(KVZ_VERSION)
        \\
    );

    const add = struct {
        fn f(m: *std.Build.Module, s: *std.Build.Dependency, gen: *std.Build.Step.WriteFile, files: []const []const u8) void {
            m.addIncludePath(gen.getDirectory());
            for ([_][]const u8{ "src", "src/extras", "src/strategies" }) |dir| m.addIncludePath(s.path(dir));
            m.addCSourceFiles(.{ .root = s.path(""), .files = files, .flags = &flags });
        }
    }.f;

    const mod = c.module(.{});
    add(mod, src, generated, &lib_sources);
    if (x86) {
        const sse41 = c.module(.{ .x86_features = &.{.sse4_1} });
        add(sse41, src, generated, &sse41_sources);
        c.addObjectTo(mod, "kvazaar_sse41", sse41);
        const avx2 = c.module(.{ .x86_features = &.{ .avx2, .bmi, .bmi2, .lzcnt, .popcnt } });
        add(avx2, src, generated, &avx2_sources);
        c.addObjectTo(mod, "kvazaar_avx2", avx2);
    }

    const lib = c.staticLibrary("kvazaar", mod);
    lib.installHeader(src.path("src/kvazaar.h"), "kvazaar.h");
    return lib;
}

const lib_sources = [_][]const u8{
    "src/bitstream.c",                        "src/cabac.c",
    "src/cfg.c",                              "src/checkpoint.c",
    "src/constraint.c",                       "src/context.c",
    "src/cu.c",                               "src/encode_coding_tree.c",
    "src/encoder.c",                          "src/encoder_state-bitstream.c",
    "src/encoder_state-ctors_dtors.c",        "src/encoder_state-geometry.c",
    "src/encoderstate.c",                     "src/extras/libmd5.c",
    "src/fast_coeff_cost.c",                  "src/filter.c",
    "src/image.c",                            "src/imagelist.c",
    "src/input_frame_buffer.c",               "src/inter.c",
    "src/intra.c",                            "src/kvazaar.c",
    "src/ml_intra_cu_depth_pred.c",           "src/nal.c",
    "src/rate_control.c",                     "src/rdo.c",
    "src/sao.c",                              "src/scalinglist.c",
    "src/search.c",                           "src/search_inter.c",
    "src/search_intra.c",                     "src/strategies/altivec/picture-altivec.c",
    "src/strategies/generic/dct-generic.c",   "src/strategies/generic/encode_coding_tree-generic.c",
    "src/strategies/generic/intra-generic.c", "src/strategies/generic/ipol-generic.c",
    "src/strategies/generic/nal-generic.c",   "src/strategies/generic/picture-generic.c",
    "src/strategies/generic/quant-generic.c", "src/strategies/generic/sao-generic.c",
    "src/strategies/sse2/picture-sse2.c",     "src/strategies/strategies-dct.c",
    "src/strategies/strategies-encode.c",     "src/strategies/strategies-intra.c",
    "src/strategies/strategies-ipol.c",       "src/strategies/strategies-nal.c",
    "src/strategies/strategies-picture.c",    "src/strategies/strategies-quant.c",
    "src/strategies/strategies-sao.c",        "src/strategyselector.c",
    "src/tables.c",                           "src/threadqueue.c",
    "src/transform.c",                        "src/videoframe.c",
};

const avx2_sources = [_][]const u8{
    "src/strategies/avx2/dct-avx2.c",     "src/strategies/avx2/encode_coding_tree-avx2.c",
    "src/strategies/avx2/intra-avx2.c",   "src/strategies/avx2/ipol-avx2.c",
    "src/strategies/avx2/picture-avx2.c", "src/strategies/avx2/quant-avx2.c",
    "src/strategies/avx2/sao-avx2.c",
};

const sse41_sources = [_][]const u8{"src/strategies/sse41/picture-sse41.c"};
