//! Host tool behind the `bundle-check` step: links a C program against a packed bundle using
//! exactly the link list of its MANIFEST.json, one archive after another with no linker groups,
//! then runs it. zig's lld finds a symbol in an archive wherever the archive sits, so with `run`
//! the same objects are linked again by the host's GNU ld, which resolves in command-line order
//! as a consumer's linker may.
//! Off Linux it only links: `msvc` names archives `<name>.lib` and links against the libc file
//! of an xwin splat when one is given.
//! usage: bundle_check <bundle-dir> <out-dir> <zig> <zig-target> <check.c> run|link gnu|msvc [libc-file]
const std = @import("std");
const Io = std.Io;

const Link = struct { name: []const u8, kind: []const u8 };
const Manifest = struct { link: []const Link };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 8 and args.len != 9) return error.Usage;
    const bundle_dir, const out_dir, const zig, const target, const source, const mode, const abi = args[1..8].*;
    const run = std.mem.eql(u8, mode, "run");
    const msvc = std.mem.eql(u8, abi, "msvc");
    const cwd = Io.Dir.cwd();

    var dir = try cwd.openDir(io, bundle_dir, .{ .iterate = true });
    defer dir.close(io);
    var root: ?[]const u8 = null;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) root = try std.fs.path.join(arena, &.{ bundle_dir, entry.name });
    }
    const bundle = root orelse return error.NoBundle;

    const manifest_text = try cwd.readFileAlloc(io, try std.fs.path.join(arena, &.{ bundle, "MANIFEST.json" }), arena, .unlimited);
    const manifest = (try std.json.parseFromSlice(Manifest, arena, manifest_text, .{ .ignore_unknown_fields = true })).value;

    var archives: std.ArrayList([]const u8) = .empty;
    var system: std.ArrayList([]const u8) = .empty;
    for (manifest.link) |entry| {
        if (std.mem.eql(u8, entry.kind, "static")) {
            const file = if (msvc) try std.fmt.allocPrint(arena, "{s}.lib", .{entry.name}) else try std.fmt.allocPrint(arena, "lib{s}.a", .{entry.name});
            try archives.append(arena, try std.fs.path.join(arena, &.{ bundle, "lib", file }));
        } else {
            try system.append(arena, try std.fmt.allocPrint(arena, "-l{s}", .{entry.name}));
        }
    }
    const include = try std.fmt.allocPrint(arena, "-I{s}/include", .{bundle});

    const exe = try std.fs.path.join(arena, &.{ out_dir, "bundle_check" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ zig, "cc", "-target", target, "-O1", "-o", exe, source, include });
    try argv.appendSlice(arena, archives.items);
    try argv.appendSlice(arena, system.items);
    // libc++abi calls the unwinder, which the consumer's toolchain supplies (libgcc_s or libunwind).
    for (archives.items) |path| {
        if (std.mem.endsWith(u8, path, "/libc++abi.a")) try argv.append(arena, "-lunwind");
    }
    var env: ?*const std.process.Environ.Map = null;
    if (args.len == 9) {
        try init.environ_map.put("ZIG_LIBC", args[8]);
        env = init.environ_map;
    }
    try expectSuccess(io, arena, argv.items, env, "linking the bundle with lld");
    if (!run) return;
    try expectSuccess(io, arena, &.{exe}, null, "running the lld-linked program");

    const object = try std.fs.path.join(arena, &.{ out_dir, "bundle_check.o" });
    try expectSuccess(io, arena, &.{ zig, "cc", "-target", target, "-O1", "-c", "-o", object, source, include }, null, "compiling the check program");
    const gnu_exe = try std.fs.path.join(arena, &.{ out_dir, "bundle_check_gnu" });
    argv.clearRetainingCapacity();
    try argv.appendSlice(arena, &.{ "cc", "-fuse-ld=bfd", "-o", gnu_exe, object });
    try argv.appendSlice(arena, archives.items);
    try argv.append(arena, "-lgcc_s");
    try argv.appendSlice(arena, system.items);
    try expectSuccess(io, arena, argv.items, null, "linking the bundle with GNU ld");
    try expectSuccess(io, arena, &.{gnu_exe}, null, "running the GNU ld-linked program");
}

fn expectSuccess(io: Io, arena: std.mem.Allocator, argv: []const []const u8, env: ?*const std.process.Environ.Map, what: []const u8) !void {
    const result = try std.process.run(arena, io, .{ .argv = argv, .environ_map = env });
    if (!result.term.success()) {
        std.log.err("{s} failed: {t}\n{s}", .{ what, result.term, result.stderr });
        return error.CheckFailed;
    }
    if (result.stdout.len > 0) std.log.info("{s}", .{std.mem.trimEnd(u8, result.stdout, "\n")});
}
