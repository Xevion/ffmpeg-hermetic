//! Host tool standing in for FFmpeg's `gzip -nc9` plus `ffbuild/bin2c`: compresses a file into a
//! gzip stream (unless `raw`) and writes it as `ff_<name>_data[]` and `ff_<name>_len` C definitions.
//! With `source` it stands in for `tools/source2c` instead: `const char *ff_source_<name>`.
//! With `minify` the input first gets the `sed`/`tr` CSS minification of ffbuild/common.mak.
//! usage: embed <input> <output.c> <name> [raw|source|minify [raw]]
const std = @import("std");
const flate = std.compress.flate;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const mode = if (args.len >= 5) args[4] else "";
    const minify = std.mem.eql(u8, mode, "minify");
    const raw = std.mem.eql(u8, mode, "raw") or (minify and args.len == 6 and std.mem.eql(u8, args[5], "raw"));
    const usage_ok = args.len == 4 or (args.len == 5 and (raw or minify or std.mem.eql(u8, mode, "source"))) or (args.len == 6 and minify and raw);
    if (!usage_ok) return error.Usage;
    const cwd = std.Io.Dir.cwd();

    const source = try cwd.readFileAlloc(io, args[1], arena, .unlimited);
    const input = if (minify) try minifyCss(arena, source) else source;

    if (std.mem.eql(u8, mode, "source")) {
        var out: std.Io.Writer.Allocating = try .initCapacity(arena, input.len * 2 + 128);
        try out.writer.print("// Generated from {s}\nconst char *ff_source_{s} =\n", .{ std.fs.path.basename(args[1]), args[3] });
        const body = if (std.mem.endsWith(u8, input, "\n")) input[0 .. input.len - 1] else input;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            try out.writer.writeByte('"');
            for (line) |ch| {
                if (ch == '\\' or ch == '"') try out.writer.writeByte('\\');
                try out.writer.writeByte(ch);
            }
            try out.writer.writeAll("\\n\"\n");
        }
        try out.writer.writeAll(";\n");
        try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.written() });
        return;
    }

    const data = if (raw) input else blk: {
        var compressed: std.Io.Writer.Allocating = try .initCapacity(arena, input.len / 4 + 64);
        const window = try arena.alloc(u8, flate.max_window_len);
        var compress = try flate.Compress.init(&compressed.writer, window, .gzip, .best);
        try compress.writer.writeAll(input);
        try compress.finish();
        break :blk compressed.written();
    };

    var out: std.Io.Writer.Allocating = try .initCapacity(arena, data.len * 6 + 128);
    try out.writer.print("const unsigned char ff_{s}_data[] = {{ ", .{args[3]});
    for (data) |byte| try out.writer.print("0x{x:0>2}, ", .{byte});
    try out.writer.print("0x00 }};\nconst unsigned int ff_{s}_len = {d};\n", .{ args[3], data.len });
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}

/// Greedy per-line `/* */` removal, newlines to spaces, runs of spaces squeezed, one leading and
/// trailing space trimmed: the result of the sed and tr pipeline in ffbuild/common.mak.
fn minifyCss(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        var rest = line;
        while (std.mem.indexOf(u8, rest, "/*")) |open| {
            const close = std.mem.lastIndexOf(u8, rest, "*/") orelse break;
            if (close < open + 2) break;
            try joined.appendSlice(arena, rest[0..open]);
            rest = rest[close + 2 ..];
        }
        try joined.appendSlice(arena, rest);
        try joined.append(arena, ' ');
    }
    var squeezed: std.ArrayList(u8) = .empty;
    for (joined.items) |ch| {
        if (ch == ' ' and squeezed.items.len > 0 and squeezed.items[squeezed.items.len - 1] == ' ') continue;
        try squeezed.append(arena, ch);
    }
    var out: []const u8 = squeezed.items;
    if (std.mem.startsWith(u8, out, " ")) out = out[1..];
    if (std.mem.endsWith(u8, out, " ")) out = out[0 .. out.len - 1];
    return out;
}
