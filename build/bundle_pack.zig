//! Host tool that packs built archives and headers into a bundle: a directory with
//! MANIFEST.json, plus a reproducible `<name>.tar.zst` and its `.sha256`.
//! usage: bundle_pack <spec.json> <out-dir> [--lib <file name>=<archive>]... [--include <dir>]... [--license <name>=<file>]...
const std = @import("std");
const Io = std.Io;
const sha256 = std.crypto.hash.sha2.Sha256;

extern fn ZSTD_createCCtx() ?*anyopaque;
extern fn ZSTD_freeCCtx(cctx: ?*anyopaque) usize;
extern fn ZSTD_CCtx_setParameter(cctx: ?*anyopaque, param: c_int, value: c_int) usize;
extern fn ZSTD_compress2(cctx: ?*anyopaque, dst: [*]u8, dst_cap: usize, src: [*]const u8, src_size: usize) usize;
extern fn ZSTD_compressBound(src_size: usize) usize;
extern fn ZSTD_isError(code: usize) c_uint;
extern fn ZSTD_getErrorName(code: usize) [*:0]const u8;
const zstd_compression_level = 100;
const zstd_level = 19;

/// System libraries a Linux bundle may ask the consumer's linker for.
const dylib_allowlist = [_][]const u8{ "m", "pthread", "dl", "rt", "c" };

const Link = struct { name: []const u8, kind: []const u8 };
const Source = struct { name: []const u8, version: []const u8, sha256: []const u8, url: []const u8 };

const Spec = struct {
    variant: []const u8,
    ffmpeg_version: []const u8,
    bundle_rev: u32,
    target: []const u8,
    glibc_floor: []const u8,
    suffix: []const u8,
    zig: []const u8,
    link: []const Link,
    sources: []const Source,
};

const Manifest = struct {
    schema: u32 = 1,
    name: []const u8,
    variant: []const u8,
    ffmpeg_version: []const u8,
    bundle_rev: u32,
    recipe: []const u8,
    target: []const u8,
    glibc_floor: []const u8,
    zig: []const u8,
    digest: []const u8,
    link: []const Link,
    sources: []const Source,
};

const File = struct {
    path: []const u8,
    data: []const u8,

    fn lessThan(_: void, a: File, b: File) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return error.Usage;
    const cwd = Io.Dir.cwd();

    const spec_text = try cwd.readFileAlloc(io, args[1], arena, .unlimited);
    const spec = (try std.json.parseFromSlice(Spec, arena, spec_text, .{})).value;
    const out_path = args[2];

    var files: std.ArrayList(File) = .empty;
    var i: usize = 3;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.Usage;
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--lib")) {
            const eq = std.mem.indexOfScalar(u8, value, '=') orelse return error.Usage;
            const data = try normalizeArchive(arena, try cwd.readFileAlloc(io, value[eq + 1 ..], arena, .unlimited));
            try files.append(arena, .{ .path = try std.fmt.allocPrint(arena, "lib/{s}", .{value[0..eq]}), .data = data });
        } else if (std.mem.eql(u8, flag, "--include")) {
            try addTree(io, arena, &files, value, "include");
        } else if (std.mem.eql(u8, flag, "--license")) {
            const eq = std.mem.indexOfScalar(u8, value, '=') orelse return error.Usage;
            const data = try cwd.readFileAlloc(io, value[eq + 1 ..], arena, .unlimited);
            const path = try std.fmt.allocPrint(arena, "licenses/{s}/{s}", .{ value[0..eq], std.fs.path.basename(value[eq + 1 ..]) });
            try files.append(arena, .{ .path = path, .data = data });
        } else return error.Usage;
    }
    std.mem.sortUnstable(File, files.items, {}, File.lessThan);

    try checkLink(spec, files.items);

    var outer = sha256.init(.{});
    for (files.items) |f| {
        if (!isArchive(f.path)) continue;
        var inner: [sha256.digest_length]u8 = undefined;
        sha256.hash(f.data, &inner, .{});
        var line: [sha256.digest_length * 2 + 2]u8 = undefined;
        _ = try std.fmt.bufPrint(&line, "{x}  ", .{&inner});
        outer.update(&line);
        outer.update(f.path["lib/".len..]);
        outer.update("\n");
    }
    const digest = std.fmt.bytesToHex(outer.finalResult(), .lower);
    const recipe = digest[0..12];
    const name = try std.fmt.allocPrint(arena, "ffmpeg-hermetic-{s}-r{d}-{s}-{s}-{s}", .{
        spec.ffmpeg_version, spec.bundle_rev, recipe, spec.variant, spec.suffix,
    });

    const manifest: Manifest = .{
        .name = name,
        .variant = spec.variant,
        .ffmpeg_version = spec.ffmpeg_version,
        .bundle_rev = spec.bundle_rev,
        .recipe = recipe,
        .target = spec.target,
        .glibc_floor = spec.glibc_floor,
        .zig = spec.zig,
        .digest = &digest,
        .link = spec.link,
        .sources = spec.sources,
    };
    var manifest_json: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(manifest, .{ .whitespace = .indent_2 }, &manifest_json.writer);
    try manifest_json.writer.writeByte('\n');
    try files.append(arena, .{ .path = "MANIFEST.json", .data = manifest_json.written() });
    std.mem.sortUnstable(File, files.items, {}, File.lessThan);

    var out_dir = try cwd.openDir(io, out_path, .{});
    defer out_dir.close(io);
    for (files.items) |f| {
        const dest = try std.fmt.allocPrint(arena, "{s}/{s}", .{ name, f.path });
        if (std.fs.path.dirname(dest)) |parent| try out_dir.createDirPath(io, parent);
        try out_dir.writeFile(io, .{ .sub_path = dest, .data = f.data });
    }

    var tar_bytes: Io.Writer.Allocating = .init(arena);
    var tar: std.tar.Writer = .{ .underlying_writer = &tar_bytes.writer };
    try tar.writeDir(name, .{ .mode = 0o755 });
    tar.prefix = name;
    var made: std.StringHashMapUnmanaged(void) = .empty;
    for (files.items) |f| {
        var end: usize = 0;
        while (std.mem.indexOfScalarPos(u8, f.path, end, '/')) |slash| : (end = slash + 1) {
            const dir = f.path[0..slash];
            if ((try made.getOrPut(arena, dir)).found_existing) continue;
            try tar.writeDir(dir, .{ .mode = 0o755 });
        }
        try tar.writeFileBytes(f.path, f.data, .{ .mode = 0o644 });
    }
    try tar.finishPedantically();

    const compressed = try compress(arena, tar_bytes.written());
    const archive_name = try std.fmt.allocPrint(arena, "{s}.tar.zst", .{name});
    try out_dir.writeFile(io, .{ .sub_path = archive_name, .data = compressed });
    var archive_hash: [sha256.digest_length]u8 = undefined;
    sha256.hash(compressed, &archive_hash, .{});
    const sidecar = try std.fmt.allocPrint(arena, "{x}\n", .{&archive_hash});
    try out_dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}.sha256", .{archive_name}), .data = sidecar });
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn isArchive(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "lib/");
}

/// The link name of an archive: `lib/lib<name>.a`, or `lib/<name>.lib` for msvc.
fn stem(path: []const u8) []const u8 {
    const file = path["lib/".len..];
    if (std.mem.endsWith(u8, file, ".lib")) return file[0 .. file.len - ".lib".len];
    return file["lib".len .. file.len - ".a".len];
}

/// Every static link entry must be a shipped archive, and every shipped archive must be linked.
fn checkLink(spec: Spec, files: []const File) !void {
    for (spec.link) |entry| {
        if (std.mem.eql(u8, entry.kind, "dylib")) {
            if (std.mem.endsWith(u8, spec.target, "-linux-gnu") and !inList(&dylib_allowlist, entry.name)) {
                std.log.err("link entry {s} is not an allowed system library", .{entry.name});
                return error.BadLink;
            }
            continue;
        }
        var found = false;
        for (files) |f| {
            if (isArchive(f.path) and std.mem.eql(u8, stem(f.path), entry.name)) found = true;
        }
        if (!found) {
            std.log.err("link entry {s} has no archive in lib/", .{entry.name});
            return error.BadLink;
        }
    }
    for (files) |f| {
        if (!isArchive(f.path)) continue;
        const linked = for (spec.link) |entry| {
            if (std.mem.eql(u8, entry.kind, "static") and std.mem.eql(u8, entry.name, stem(f.path))) break true;
        } else false;
        if (!linked) {
            std.log.err("{s} is shipped but missing from the link list", .{f.path});
            return error.BadLink;
        }
    }
}

fn addTree(io: Io, arena: std.mem.Allocator, files: *std.ArrayList(File), root: []const u8, dest: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const data = try entry.dir.readFileAlloc(io, entry.basename, arena, .unlimited);
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dest, entry.path });
        const existing = for (files.items) |f| {
            if (std.mem.eql(u8, f.path, path)) break f;
        } else null;
        if (existing) |f| {
            if (!std.mem.eql(u8, f.data, data)) {
                std.log.err("{s} differs between include trees", .{path});
                return error.ConflictingHeader;
            }
        } else try files.append(arena, .{ .path = path, .data = data });
    }
}

fn compress(arena: std.mem.Allocator, input: []const u8) ![]u8 {
    const cctx = ZSTD_createCCtx() orelse return error.ZstdInit;
    defer _ = ZSTD_freeCCtx(cctx);
    try check(ZSTD_CCtx_setParameter(cctx, zstd_compression_level, zstd_level));
    const out = try arena.alloc(u8, ZSTD_compressBound(input.len));
    const n = ZSTD_compress2(cctx, out.ptr, out.len, input.ptr, input.len);
    try check(n);
    return out[0..n];
}

fn check(code: usize) !void {
    if (ZSTD_isError(code) == 0) return;
    std.log.err("zstd: {s}", .{ZSTD_getErrorName(code)});
    return error.Zstd;
}

const ar_magic = "!<arch>\n";
const ar_header_len = 60;

const ArMember = struct { name: []const u8, data: []const u8 };

/// Rewrites a GNU archive so it depends only on its objects: member names lose their build-cache
/// directory, and ownership, mode and timestamps are fixed. The symbol table, and the second
/// linker member COFF archives carry after it, are rebuilt for the new member offsets.
fn normalizeArchive(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, input, ar_magic)) return error.NotAnArchive;
    // Darwin's BSD archives from zig already hold bare member names and zeroed metadata.
    if (std.mem.startsWith(u8, input[ar_magic.len..], "#1/")) return input;
    var members: std.ArrayList(ArMember) = .empty;
    var long_names: []const u8 = "";
    var symtab: []const u8 = "";
    var coff_symtab: []const u8 = "";
    var offsets: std.ArrayList(usize) = .empty;
    var pos: usize = ar_magic.len;
    while (pos < input.len) {
        if (pos + ar_header_len > input.len) return error.TruncatedArchive;
        const header = input[pos..][0..ar_header_len];
        const size = try std.fmt.parseInt(usize, std.mem.trim(u8, header[48..58], " "), 10);
        const body = input[pos + ar_header_len ..][0..size];
        const raw = std.mem.trimEnd(u8, header[0..16], " ");
        if (std.mem.eql(u8, raw, "/")) {
            if (symtab.len == 0) symtab = body else coff_symtab = body;
        } else if (std.mem.eql(u8, raw, "//")) {
            long_names = body;
        } else {
            var name = raw;
            if (raw.len > 1 and raw[0] == '/') {
                const start = try std.fmt.parseInt(usize, raw[1..], 10);
                // GNU ends each long name with "/\n", COFF archives with a NUL.
                const end = std.mem.indexOfAnyPos(u8, long_names, start, "\n\x00") orelse return error.BadLongName;
                name = long_names[start..end];
            }
            name = std.mem.trimEnd(u8, name, "/");
            try members.append(arena, .{ .name = std.fs.path.basename(name), .data = body });
            try offsets.append(arena, pos);
        }
        pos += ar_header_len + size + (size & 1);
    }

    var names_table: std.ArrayList(u8) = .empty;
    const refs = try arena.alloc([]const u8, members.items.len);
    for (members.items, refs) |m, *ref| {
        if (m.name.len < 16) {
            ref.* = try std.fmt.allocPrint(arena, "{s}/", .{m.name});
        } else {
            ref.* = try std.fmt.allocPrint(arena, "/{d}", .{names_table.items.len});
            try names_table.appendSlice(arena, m.name);
            try names_table.appendSlice(arena, "/\n");
        }
    }

    const symbol_count: usize = if (symtab.len >= 4) std.mem.readInt(u32, symtab[0..4], .big) else 0;
    var symtab_len: usize = 0;
    if (symtab.len > 0) symtab_len = symtab.len;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, ar_magic);
    var layout = ar_magic.len;
    if (symtab_len > 0) layout += ar_header_len + symtab_len + (symtab_len & 1);
    if (coff_symtab.len > 0) layout += ar_header_len + coff_symtab.len + (coff_symtab.len & 1);
    if (names_table.items.len > 0) layout += ar_header_len + names_table.items.len + (names_table.items.len & 1);
    const new_offsets = try arena.alloc(usize, members.items.len);
    for (members.items, new_offsets) |m, *off| {
        off.* = layout;
        layout += ar_header_len + m.data.len + (m.data.len & 1);
    }

    if (symtab_len > 0) {
        var table = try arena.dupe(u8, symtab);
        for (0..symbol_count) |i| {
            const slot = table[4 + i * 4 ..][0..4];
            const old = std.mem.readInt(u32, slot, .big);
            const index = std.mem.indexOfScalar(usize, offsets.items, old) orelse return error.BadSymbolTable;
            std.mem.writeInt(u32, slot, @intCast(new_offsets[index]), .big);
        }
        try writeArMember(arena, &out, "/", table);
    }
    if (coff_symtab.len > 0) {
        // Little-endian member count and member offsets, then the symbol indices into them.
        var table = try arena.dupe(u8, coff_symtab);
        const member_count = std.mem.readInt(u32, table[0..4], .little);
        for (0..member_count) |i| {
            const slot = table[4 + i * 4 ..][0..4];
            const index = std.mem.indexOfScalar(usize, offsets.items, std.mem.readInt(u32, slot, .little)) orelse return error.BadSymbolTable;
            std.mem.writeInt(u32, slot, @intCast(new_offsets[index]), .little);
        }
        try writeArMember(arena, &out, "/", table);
    }
    if (names_table.items.len > 0) try writeArMember(arena, &out, "//", names_table.items);
    for (members.items, refs) |m, ref| try writeArMember(arena, &out, ref, m.data);
    return out.items;
}

fn writeArMember(arena: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, data: []const u8) !void {
    try out.print(arena, "{s: <16}{s: <12}{s: <6}{s: <6}{s: <8}{d: <10}`\n", .{ name, "0", "0", "0", "100644", data.len });
    try out.appendSlice(arena, data);
    if (data.len & 1 == 1) try out.append(arena, '\n');
}
