const std = @import("std");
const Ctx = @import("build/Ctx.zig");
const Nasm = @import("build/Nasm.zig");

const Library = struct {
    name: []const u8,
    build: *const fn (Ctx, Nasm) *std.Build.Step.Compile,
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
    .{ .name = "x264", .build = @import("build/x264.zig").build },
    .{ .name = "x265", .build = @import("build/x265.zig").build },
    .{ .name = "libdrm", .build = @import("build/libdrm.zig").build },
    .{ .name = "libva", .build = @import("build/libva.zig").build },
};

pub fn build(b: *std.Build) void {
    const c: Ctx = .{
        .b = b,
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast }),
    };
    const only = b.option([]const u8, "only", "Build a single library (zlib, opus, dav1d, ...)");
    const nasm = Nasm.init(c);

    for (libraries) |lib| {
        if (only) |name| if (!std.mem.eql(u8, name, lib.name)) continue;
        b.installArtifact(lib.build(c, nasm));
    }
}
