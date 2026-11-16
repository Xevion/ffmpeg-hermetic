//! Shared settings for every library in the graph: one target, one optimize mode.
const std = @import("std");
const Ctx = @This();

b: *std.Build,
target: std.Build.ResolvedTarget,
optimize: std.builtin.Optimize,

pub fn os(c: Ctx) std.Target.Os.Tag {
    return c.target.result.os.tag;
}

pub fn arch(c: Ctx) std.Target.Cpu.Arch {
    return c.target.result.cpu.arch;
}

pub fn isWindows(c: Ctx) bool {
    return c.os() == .windows;
}

pub fn isMsvc(c: Ctx) bool {
    return c.target.result.abi == .msvc;
}

/// The unpacked upstream tarball pinned in build.zig.zon under `name`.
pub fn upstream(c: Ctx, name: []const u8) *std.Build.Dependency {
    return c.b.dependency(name, .{});
}

pub const ModuleOptions = struct {
    cpp: bool = false,
    /// Extra CPU features, for sources upstream builds with `-msse4.1` and the like behind
    /// runtime dispatch. Zig takes features from the target, so per-file `-m` flags are ignored.
    x86_features: []const std.Target.x86.Feature = &.{},
};

/// A C (or C++) module for one static library.
pub fn module(c: Ctx, opts: ModuleOptions) *std.Build.Module {
    var target = c.target;
    if (opts.x86_features.len > 0) {
        var q = c.target.query;
        for (opts.x86_features) |f| q.cpu_features_add.addFeature(@backingInt(f));
        target = c.b.resolveTargetQuery(q);
    }
    return c.b.createModule(.{
        .target = target,
        .optimize = c.optimize,
        .link_libc = true,
        .link_libcpp = if (opts.cpp) true else null,
        .pic = true,
        // Upstream code relies on behavior UBSan traps on, and configure probes never see it.
        .sanitize_c = .off,
    });
}

/// Compiles `m` (typically an ISA module) to an object that becomes part of `into`.
pub fn addObjectTo(c: Ctx, into: *std.Build.Module, name: []const u8, m: *std.Build.Module) void {
    into.addObject(c.b.addObject(.{ .name = name, .root_module = m }));
}

pub fn staticLibrary(c: Ctx, name: []const u8, root_module: *std.Build.Module) *std.Build.Step.Compile {
    return c.b.addLibrary(.{ .name = name, .linkage = .static, .root_module = root_module });
}
