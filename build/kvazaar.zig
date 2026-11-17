const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const src = c.upstream("kvazaar");
    const x86 = c.target.result.cpu.arch.isX86();
    const msvc = c.isMsvc();
    const flags: []const []const u8 = if (msvc)
        &.{ "-DCMAKE_BUILD", "-DKVZ_DLL_EXPORTS", "-DNDEBUG", "-DWIN32_LEAN_AND_MEAN", "-DWIN32", "-DWIN64", "-D_USE_MATH_DEFINES" }
    else
        &.{ "-DCMAKE_BUILD", "-DKVZ_DLL_EXPORTS", "-DNDEBUG" };

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

    var includes: std.ArrayList(std.Build.LazyPath) = .empty;
    includes.append(c.b.allocator, generated.getDirectory()) catch @panic("OOM");
    includes.appendSlice(c.b.allocator, c.includeDirs(src.path(""), &.{ "src", "src/extras", "src/strategies" })) catch @panic("OOM");
    if (msvc) includes.append(c.b.allocator, src.path("src/threadwrapper/include")) catch @panic("OOM");
    const setup: Ctx.Setup = .{ .includes = includes.items };

    const mod = c.module(.{});
    setup.apply(mod);
    mod.addCSourceFiles(.{ .root = src.path(""), .files = &lib_sources, .flags = flags });
    if (msvc) {
        // MSVC has no pthreads, so upstream ships a wrapper over Win32 threads. It needs
        // std::shared_mutex, and clang defaults to C++14 for msvc targets.
        c.addSources(mod, "kvazaar_threadwrapper", .{
            .module = .{ .cpp = true },
            .setup = setup,
            .groups = &.{.{
                .root = src.path(""),
                .files = &.{ "src/threadwrapper/src/pthread.cpp", "src/threadwrapper/src/semaphore.cpp" },
                .flags = std.mem.concat(c.b.allocator, []const u8, &.{ flags, &.{"-std=c++17"} }) catch @panic("OOM"),
            }},
        });
    }
    if (x86) {
        c.addSources(mod, "kvazaar_sse41", .{
            .module = .{ .x86_features = &.{.sse4_1} },
            .setup = setup,
            .groups = &.{.{ .root = src.path(""), .files = &sse41_sources, .flags = flags }},
        });
        c.addSources(mod, "kvazaar_avx2", .{
            .module = .{ .x86_features = &.{ .avx2, .bmi, .bmi2, .lzcnt, .popcnt } },
            .setup = setup,
            .groups = &.{.{ .root = src.path(""), .files = &avx2_sources, .flags = flags }},
        });
    } else {
        // The strategy registries call the ISA registration functions unconditionally; off x86 these files compile to stubs.
        mod.addCSourceFiles(.{ .root = src.path(""), .files = &(sse41_sources ++ avx2_sources), .flags = flags });
    }

    const lib = c.staticLibrary("kvazaar", mod);
    lib.installHeader(src.path("src/kvazaar.h"), "kvazaar.h");
    return c.single(lib);
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
