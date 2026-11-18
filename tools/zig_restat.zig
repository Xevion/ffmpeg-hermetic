//! Rewrites a restored zig cache's manifests so files whose contents are unchanged keep hitting.
//!
//! zig 0.17's cache treats an input whose size, inode or mtime changed as changed, even when its
//! contents match, and an unpacked cache archive or package directory gives every file a new inode.
//! For each manifest record whose file still hashes to the recorded digest, this stores the file's
//! current stat. Records whose contents differ, or that it cannot resolve, are left for zig to miss.
//! Manifests of the build configuration itself (those recording the root build.zig) are deleted:
//! CI does not cache the configured graph in c/, and a hit on one opens that missing file.
//!
//! TODO: delete this tool and its CI step once the pinned zig is 0.18, which fixes the comparison.
//!
//! usage: zig run tools/zig_restat.zig -- <cache dir> <build root> <zig lib dir>
//! The cache dir serves as both the local and the global cache, as CI sets them up.
const std = @import("std");
const Io = std.Io;
const Cache = std.Build.Cache;
const File = Cache.Manifest.File;
const PathPrefix = std.zig.Server.Message.PathPrefix;

const Known = struct {
    stat: Io.File.Stat,
    digest: Cache.BinDigest,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) return error.Usage;
    const cwd = Io.Dir.cwd();

    // No restored cache, nothing to rewrite.
    var manifests = cwd.openDir(io, try std.fs.path.join(arena, &.{ args[1], "h" }), .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer manifests.close(io);

    var prefixes: [@typeInfo(PathPrefix).@"enum".field_names.len]Io.Dir = undefined;
    for (&prefixes, 0..) |*dir, i| {
        const path = switch (@as(PathPrefix, @fromBackingInt(@intCast(i)))) {
            .cwd, .build_root => args[2],
            .zig_lib => args[3],
            .local_cache, .global_cache => args[1],
        };
        dir.* = try cwd.openDir(io, path, .{});
    }

    // Thousands of manifests list the same headers; hash each file once.
    var known: std.StringHashMapUnmanaged(?Known) = .empty;
    var counts: struct { manifests: usize = 0, rewritten: usize = 0, dropped: usize = 0, taken: usize = 0, left: usize = 0 } = .{};

    var it = manifests.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or entry.name.len != Cache.hex_digest_len) continue;
        const contents = manifests.readFileAlloc(io, entry.name, gpa, .unlimited) catch continue;
        defer gpa.free(contents);
        counts.manifests += 1;

        var changed = false;
        var configuration = false;
        var off: usize = 0;
        while (off + 1 < contents.len) {
            const file_off: File.Offset = @fromBackingInt(@intCast(@as(u32, @intCast(off))));
            const file = file_off.getFallible(contents) catch break;
            const path = file_off.pathFallible(contents) catch break;
            off += File.sizeOf(path.len);
            if (file.flags.is_directory or file.flags.metadata_only or path.len == 0) continue;
            if (file.flags.prefix >= prefixes.len) continue;
            if (file.flags.prefix == @backingInt(PathPrefix.build_root) and std.mem.eql(u8, path, "build.zig")) configuration = true;

            const key = try std.fmt.allocPrint(arena, "{d}/{s}", .{ file.flags.prefix, path });
            const gop = try known.getOrPut(arena, key);
            if (!gop.found_existing) gop.value_ptr.* = current(io, prefixes[file.flags.prefix], path);
            const now = gop.value_ptr.* orelse {
                counts.left += 1;
                continue;
            };
            const mtime: i64 = @intCast(now.stat.mtime.toNanoseconds());
            if (file.size == now.stat.size and file.inode == now.stat.inode and file.mtime == mtime) continue;
            if (!std.mem.eql(u8, &file.digest, &now.digest)) {
                counts.left += 1;
                continue;
            }
            file.size = now.stat.size;
            file.inode = now.stat.inode;
            file.mtime = mtime;
            changed = true;
            counts.taken += 1;
        }
        if (configuration) {
            try manifests.deleteFile(io, entry.name);
            counts.dropped += 1;
        } else if (changed) {
            try manifests.writeFile(io, .{ .sub_path = entry.name, .data = contents });
            counts.rewritten += 1;
        }
    }
    std.debug.print("zig_restat: {d} manifests, {d} rewritten, {d} configurations dropped; {d} records took a new stat, {d} left\n", .{
        counts.manifests, counts.rewritten, counts.dropped, counts.taken, counts.left,
    });
}

fn current(io: Io, dir: Io.Dir, path: []const u8) ?Known {
    const file = dir.openFile(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.kind != .file) return null;
    var hasher = Cache.hasher_init;
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = file.readPositional(io, &.{&buffer}, offset) catch return null;
        if (n == 0) break;
        hasher.update(buffer[0..n]);
        offset += n;
    }
    var digest: Cache.BinDigest = undefined;
    hasher.final(&digest);
    return .{ .stat = stat, .digest = digest };
}
