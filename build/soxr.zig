const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "soxr",
    .version = "0.1.3",
    .licenses = &.{ "COPYING.LGPL", "LICENCE" },
    .system_libs = .{ .linux = &.{"m"} },
};

/// The SoX resampler. Its double-precision SIMD engine is built with AVX and chosen at runtime.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const b = c.b;
    const src = c.upstream("soxr");
    const x86 = c.arch() == .x86_64;
    const msvc = c.isMsvc();

    const config = b.addConfigHeader(.{
        .style = .{ .cmake = src.path("soxr-config.h.in") },
        .include_path = "soxr-config.h",
    }, .{
        .AVCODEC_FOUND = false,
        .AVUTIL_FOUND = false,
        .WITH_PFFFT = x86,
        .HAVE_FENV_H = true,
        .HAVE_STDBOOL_H = !msvc,
        .HAVE_STDINT_H = true,
        .HAVE_LRINT = !msvc,
        .HAVE_BIGENDIAN = c.arch().endian() == .big,
        .WITH_CR32 = true,
        .WITH_CR32S = x86,
        .WITH_CR64 = true,
        .WITH_CR64S = x86,
        .WITH_VR32 = true,
        .WITH_HI_PREC_CLOCK = true,
        .WITH_FLOAT_STD_PREC_CLOCK = false,
        .WITH_DEV_TRACE = true,
    });
    const flags: []const []const u8 = &.{ "-DSOXR_LIB", "-std=gnu89" };
    const setup: Ctx.Setup = .{ .config_headers = &.{config}, .includes = &.{src.path("src")} };

    const mod = c.module(.{});
    setup.apply(mod);
    mod.addCSourceFiles(.{ .root = src.path("src"), .files = &common, .flags = flags });
    if (x86) {
        mod.addCSourceFiles(.{ .root = src.path("src"), .files = &simd32, .flags = flags });
        c.addSources(mod, "soxr_avx", .{
            .module = .{ .x86_features = &.{.avx} },
            .setup = setup,
            .groups = &.{.{ .root = src.path("src"), .files = &simd64, .flags = flags }},
        });
    }

    const lib = c.staticLibrary("soxr", mod);
    lib.installHeader(src.path("src/soxr.h"), "soxr.h");
    return c.single(lib);
}

const common = [_][]const u8{
    "soxr.c", "data-io.c", "dbesi0.c", "filter.c", "fft4g64.c", "cr.c", "cr32.c", "fft4g32.c", "cr64.c", "vr32.c",
};
const simd32 = [_][]const u8{ "cr32s.c", "pffft32s.c", "util32s.c" };
const simd64 = [_][]const u8{ "cr64s.c", "pffft64s.c", "util64s.c" };
