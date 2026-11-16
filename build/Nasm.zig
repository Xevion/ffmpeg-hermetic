//! Assembles x86 `.asm` sources with a nasm built from source for the host.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @This();

exe: *std.Build.Step.Compile,
format: []const u8,

pub fn init(c: Ctx) Nasm {
    const dep = c.b.dependency("nasm", .{ .target = c.b.graph.host, .optimize = .ReleaseFast });
    const t = c.target.result;
    const bits64 = t.cpu.arch == .x86_64;
    const format = switch (t.os.tag) {
        .windows => if (bits64) "win64" else "win32",
        .macos, .ios, .tvos, .watchos, .visionos => if (bits64) "macho64" else "macho32",
        else => if (bits64) "elf64" else "elf32",
    };
    return .{ .exe = dep.artifact("nasm"), .format = format };
}

pub const Options = struct {
    root: std.Build.LazyPath,
    files: []const []const u8,
    /// Directories searched by `%include`, in order.
    include_dirs: []const std.Build.LazyPath = &.{},
    flags: []const []const u8 = &.{},
};

/// Assembles every file and adds the objects to `into`.
pub fn addFiles(n: Nasm, c: Ctx, into: *std.Build.Module, opts: Options) void {
    for (opts.files) |file| {
        const run = c.b.addRunArtifact(n.exe);
        run.addArgs(&.{ "-f", n.format });
        for (opts.include_dirs) |dir| run.addDirectoryArg2(dir, .{ .prefix = "-I", .suffix = "/" });
        run.addArgs(opts.flags);
        run.addArg("-MD");
        _ = run.addDepFileOutputArg2("obj.d", .{});
        run.addFileArg2(opts.root.path(c.b, file), .{});
        run.addArg("-o");
        const obj = run.addOutputFileArg2(objName(c.b, file), .{});
        into.addObjectFile(obj);
    }
}

fn objName(b: *std.Build, file: []const u8) []const u8 {
    const base = std.fs.path.stem(file);
    return b.fmt("{s}.o", .{base});
}
