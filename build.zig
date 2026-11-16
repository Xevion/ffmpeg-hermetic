const std = @import("std");
const Ctx = @import("build/Ctx.zig");
const Nasm = @import("build/Nasm.zig");
const ffmpeg = @import("build/ffmpeg.zig");

const Library = struct {
    name: []const u8,
    build: *const fn (Ctx, Nasm) *std.Build.Step.Compile,
    gpl: bool = false,
    linux_only: bool = false,
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

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const c: Ctx = .{
        .b = b,
        .target = b.standardTargetOptions(.{}),
        .optimize = optimize,
        .gpl = b.option(bool, "gpl", "Build x264, x265 and FFmpeg's GPL configuration") orelse false,
        .strip = b.option(bool, "strip", "Omit debug info (default: on unless Debug)") orelse (optimize != .debug),
    };
    const only = b.option([]const u8, "only", "Build a single library (zlib, opus, dav1d, ..., ffmpeg)");
    const nasm = Nasm.init(c);
    const with_ffmpeg = if (only) |name| std.mem.eql(u8, name, "ffmpeg") else true;

    var deps: std.ArrayList(*std.Build.Step.Compile) = .empty;
    for (libraries) |lib| {
        if (lib.gpl and !c.gpl) continue;
        if (lib.linux_only and c.os() != .linux) continue;
        if (only) |name| if (!with_ffmpeg and !std.mem.eql(u8, name, lib.name)) continue;
        const artifact = lib.build(c, nasm);
        b.installArtifact(artifact);
        deps.append(b.allocator, artifact) catch @panic("OOM");
    }
    if (with_ffmpeg) {
        for (ffmpeg.build(c, nasm, deps.items)) |artifact| b.installArtifact(artifact);
    }
}
