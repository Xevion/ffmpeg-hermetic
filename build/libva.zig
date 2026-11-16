//! libva with only the DRM backend. libva and libva-drm share one archive, `va`.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// Compiled in because a static libva has no loader path to find drivers from.
const driver_dirs = "/usr/lib/x86_64-linux-gnu/dri:/usr/lib64/dri:/usr/lib/dri:/usr/local/lib/dri";

pub fn build(c: Ctx, _: Nasm) *std.Build.Step.Compile {
    const b = c.b;
    const src = c.upstream("libva");
    const drm = c.upstream("libdrm");

    const version = b.addConfigHeader(.{
        .style = .{ .meson = src.path("va/va_version.h.in") },
        .include_path = "va/va_version.h",
    }, .{
        .VA_API_MAJOR_VERSION = 1,
        .VA_API_MINOR_VERSION = 23,
        .VA_API_MICRO_VERSION = 0,
        .VA_API_VERSION = "1.23.0",
    });

    const mod = c.module(.{});
    mod.addConfigHeader(version);
    for ([_]std.Build.LazyPath{ src.path(""), src.path("va"), drm.path(""), drm.path("include/drm") }) |dir| {
        mod.addIncludePath(dir);
    }
    const common = [_][]const u8{ "-DHAVE_SECURE_GETENV", "-D_FILE_OFFSET_BITS=64" };
    mod.addCSourceFiles(.{
        .root = src.path("va"),
        .files = &.{ "va.c", "va_compat.c", "va_str.c", "va_trace.c" },
        .flags = &(common ++ .{ "-DSYSCONFDIR=\"/etc\"", "-DVA_DRIVERS_PATH=\"" ++ driver_dirs ++ "\"" }),
    });
    mod.addCSourceFiles(.{
        .root = src.path("va/drm"),
        .files = &.{ "va_drm.c", "va_drm_auth.c", "va_drm_utils.c" },
        .flags = &common,
    });

    const lib = c.staticLibrary("va", mod);
    lib.installHeadersDirectory(src.path("va"), "va", .{ .include_extensions = &public_headers });
    lib.installHeader(src.path("va/drm/va_drm.h"), "va/va_drm.h");
    lib.installConfigHeader(version);
    return lib;
}

const public_headers = [_][]const u8{
    "va.h",           "va_backend.h",   "va_backend_prot.h", "va_backend_vpp.h", "va_compat.h",
    "va_dec_hevc.h",  "va_dec_jpeg.h",  "va_dec_vp8.h",      "va_dec_vp9.h",     "va_dec_av1.h",
    "va_dec_vvc.h",   "va_drmcommon.h", "va_egl.h",          "va_enc_hevc.h",    "va_enc_h264.h",
    "va_enc_jpeg.h",  "va_enc_vp8.h",   "va_fei.h",          "va_fei_h264.h",    "va_fei_hevc.h",
    "va_enc_mpeg2.h", "va_enc_vp9.h",   "va_enc_av1.h",      "va_str.h",         "va_tpi.h",
    "va_prot.h",      "va_vpp.h",
};
