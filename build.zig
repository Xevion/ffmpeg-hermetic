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
};

const libraries = [_]Library{
    .{ .name = "zlib", .build = @import("build/zlib.zig").build },
    .{ .name = "opus", .build = @import("build/opus.zig").build },
    .{ .name = "lame", .build = @import("build/lame.zig").build },
    .{ .name = "kvazaar", .build = @import("build/kvazaar.zig").build },
    .{ .name = "dav1d", .build = @import("build/dav1d.zig").build },
    .{ .name = "openh264", .build = @import("build/openh264.zig").build },
    .{ .name = "svt_av1", .build = @import("build/svt_av1.zig").build },
    .{ .name = "libaom", .build = @import("build/libaom.zig").build },
    .{ .name = "libvpx", .build = @import("build/libvpx.zig").build },
    .{ .name = "x264", .build = @import("build/x264.zig").build, .gpl = true },
    .{ .name = "x265", .build = @import("build/x265.zig").build, .gpl = true },
    .{ .name = "libdrm", .build = @import("build/libdrm.zig").build, .linux_only = true },
    .{ .name = "libva", .build = @import("build/libva.zig").build, .linux_only = true },
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

    var deps: std.ArrayList(*std.Build.Step.Compile) = .empty;
    for (libraries) |lib| {
        if (lib.gpl and !c.gpl) continue;
        if (lib.linux_only and c.os() != .linux) continue;
        if (c.isMsvc() and (lib.msvc == .none or (lib.msvc == .x86_64 and c.arch() != .x86_64))) continue;
        if (only) |name| if (!with_ffmpeg and !std.mem.eql(u8, name, lib.name)) continue;
        buildLibrary(c, nasm, lib, &deps);
    }
    if (with_ffmpeg) {
        for (ffmpeg.build(c, nasm, deps.items)) |artifact| b.installArtifact(artifact);
    }
    c.applyLibc();
}
