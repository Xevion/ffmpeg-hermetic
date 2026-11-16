const std = @import("std");
const Ctx = @import("build/Ctx.zig");
const Nasm = @import("build/Nasm.zig");
const ffmpeg = @import("build/ffmpeg.zig");

const Library = struct {
    name: []const u8,
    build: ?*const fn (Ctx, Nasm) *std.Build.Step.Compile = null,
    /// For libraries that ship several archives; the first is the one dependents link.
    build_all: ?*const fn (Ctx, Nasm) []const *std.Build.Step.Compile = null,
    /// Libraries whose installed headers this one compiles against, built first.
    needs: []const []const u8 = &.{},
    gpl: bool = false,
    linux_only: bool = false,
    /// Which windows-msvc targets upstream supports.
    msvc: enum { all, x86_64, none } = .all,
    /// FFmpeg accepts this library in GPL builds only with --enable-version3 (`-Dversion3`).
    gpl_needs_version3: bool = false,
    /// configure names FFmpeg enables when this library is built (`--enable-<name>`).
    ffmpeg: []const []const u8 = &.{},
};

const libraries = [_]Library{
    .{ .name = "zlib", .build = @import("build/zlib.zig").build, .ffmpeg = &.{"zlib"} },
    .{ .name = "opus", .build = @import("build/opus.zig").build, .ffmpeg = &.{"libopus"} },
    .{ .name = "lame", .build = @import("build/lame.zig").build, .ffmpeg = &.{"libmp3lame"} },
    .{ .name = "kvazaar", .build = @import("build/kvazaar.zig").build, .ffmpeg = &.{"libkvazaar"} },
    .{ .name = "dav1d", .build = @import("build/dav1d.zig").build, .ffmpeg = &.{"libdav1d"} },
    .{ .name = "openh264", .build = @import("build/openh264.zig").build, .ffmpeg = &.{"libopenh264"} },
    .{ .name = "svt_av1", .build = @import("build/svt_av1.zig").build, .ffmpeg = &.{"libsvtav1"} },
    .{ .name = "libaom", .build = @import("build/libaom.zig").build, .ffmpeg = &.{"libaom"} },
    .{ .name = "libvpx", .build = @import("build/libvpx.zig").build, .ffmpeg = &.{"libvpx"} },
    .{ .name = "x264", .build = @import("build/x264.zig").build, .gpl = true, .ffmpeg = &.{"libx264"} },
    .{ .name = "x265", .build = @import("build/x265.zig").build, .gpl = true, .ffmpeg = &.{"libx265"} },
    .{ .name = "libogg", .build = @import("build/libogg.zig").build },
    .{ .name = "libvorbis", .build_all = @import("build/libvorbis.zig").build, .needs = &.{"libogg"} },
    .{ .name = "libwebp", .build_all = @import("build/libwebp.zig").build },
    .{ .name = "openjpeg", .build = @import("build/openjpeg.zig").build },
    .{ .name = "libtheora", .build_all = @import("build/libtheora.zig").build, .needs = &.{"libogg"} },
    .{ .name = "soxr", .build = @import("build/soxr.zig").build },
    .{ .name = "zimg", .build = @import("build/zimg.zig").build },
    .{ .name = "bzip2", .build = @import("build/bzip2.zig").build },
    .{ .name = "xz", .build = @import("build/xz.zig").build },
    .{ .name = "freetype", .build = @import("build/freetype.zig").build },
    .{ .name = "fribidi", .build = @import("build/fribidi.zig").build },
    .{ .name = "harfbuzz", .build = @import("build/harfbuzz.zig").build, .needs = &.{"freetype"} },
    .{ .name = "libass", .build = @import("build/libass.zig").build, .needs = &.{ "freetype", "fribidi", "harfbuzz" } },
    .{ .name = "openssl", .build_all = @import("build/openssl.zig").build, .linux_only = true, .gpl_needs_version3 = true, .ffmpeg = &.{"openssl"} },
    .{ .name = "vulkan_headers", .build = @import("build/vulkan_headers.zig").build, .ffmpeg = &.{"vulkan"} },
    .{ .name = "amf", .build = @import("build/amf.zig").build, .ffmpeg = &.{"amf"} },
    .{ .name = "libvpl", .build = @import("build/libvpl.zig").build, .ffmpeg = &.{"libvpl"} },
    .{ .name = "opencl_headers", .build = @import("build/opencl_headers.zig").build },
    .{ .name = "opencl", .build = @import("build/opencl.zig").build, .needs = &.{"opencl_headers"}, .ffmpeg = &.{"opencl"} },
    .{ .name = "libdrm", .build = @import("build/libdrm.zig").build, .linux_only = true, .ffmpeg = &.{"libdrm"} },
    .{ .name = "libva", .build = @import("build/libva.zig").build, .linux_only = true, .ffmpeg = &.{"vaapi"} },
};

fn find(name: []const u8) Library {
    for (libraries) |lib| if (std.mem.eql(u8, lib.name, name)) return lib;
    std.debug.panic("unknown library {s}", .{name});
}

/// Builds `lib` once, after the libraries it needs, and records its archives in `c.built`.
fn buildLibrary(c: Ctx, nasm: Nasm, lib: Library, out: *std.ArrayList(*std.Build.Step.Compile)) void {
    if (c.built.contains(lib.name)) return;
    for (lib.needs) |need| buildLibrary(c, nasm, find(need), out);
    const archives: []const *std.Build.Step.Compile = if (lib.build_all) |f| f(c, nasm) else blk: {
        const one = c.b.allocator.alloc(*std.Build.Step.Compile, 1) catch @panic("OOM");
        one[0] = lib.build.?(c, nasm);
        break :blk one;
    };
    c.built.put(c.b.allocator, lib.name, archives) catch @panic("OOM");
    for (archives) |artifact| {
        c.b.installArtifact(artifact);
        out.append(c.b.allocator, artifact) catch @panic("OOM");
    }
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const c: Ctx = .{
        .b = b,
        .target = b.standardTargetOptions(.{}),
        .optimize = optimize,
        .gpl = b.option(bool, "gpl", "Build x264, x265 and FFmpeg's GPL configuration") orelse false,
        .strip = b.option(bool, "strip", "Omit debug info (default: on unless Debug)") orelse (optimize != .debug),
        .built = b.allocator.create(Ctx.Built) catch @panic("OOM"),
        .winsdk = if (b.option([]const u8, "winsdk", "xwin splat directory (MSVC CRT + Windows SDK) for msvc targets off Windows")) |dir| b.pathResolve(&.{dir}) else null,
    };
    c.built.* = .empty;
    const only = b.option([]const u8, "only", "Build a single library (zlib, opus, dav1d, ..., ffmpeg)");
    const nasm = Nasm.init(c);
    const with_ffmpeg = if (only) |name| std.mem.eql(u8, name, "ffmpeg") else true;

    const version3 = b.option(bool, "version3", "Use FFmpeg's (L)GPL version 3 licensing, which admits OpenSSL 3 in GPL builds") orelse false;
    var deps: std.ArrayList(*std.Build.Step.Compile) = .empty;
    for (libraries) |lib| {
        const wanted = b.option(bool, lib.name, b.fmt("Build {s} and enable it in FFmpeg (default: true)", .{lib.name})) orelse true;
        if (!wanted or (lib.gpl and !c.gpl) or (lib.gpl_needs_version3 and c.gpl and !version3)) continue;
        if (lib.linux_only and c.os() != .linux) continue;
        if (c.isMsvc() and (lib.msvc == .none or (lib.msvc == .x86_64 and c.arch() != .x86_64))) continue;
        if (only) |name| if (!with_ffmpeg and !std.mem.eql(u8, name, lib.name)) continue;
        buildLibrary(c, nasm, lib, &deps);
    }
    if (with_ffmpeg) {
        var enabled: std.ArrayList([]const u8) = .empty;
        for (libraries) |lib| if (c.built.contains(lib.name)) enabled.appendSlice(b.allocator, lib.ffmpeg) catch @panic("OOM");
        const ffmpeg_libs = ffmpeg.build(c, nasm, deps.items, .{ .libraries = enabled.items, .version3 = version3 });
        for (ffmpeg_libs) |artifact| b.installArtifact(artifact);
    }
    c.applyLibc();
}
