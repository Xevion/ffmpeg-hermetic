//! Host tool standing in for FFmpeg's `gzip -nc9` plus `ffbuild/bin2c`: compresses a file into a
//! gzip stream (unless `raw`) and writes it as `ff_<name>_data[]` and `ff_<name>_len` C definitions.
//! With `source` it stands in for `tools/source2c` instead: `const char *ff_source_<name>`.
//! usage: embed <input> <output.c> <name> [raw|source]
const std = @import("std");
const flate = std.compress.flate;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const mode = if (args.len == 5) args[4] else "";
    if (args.len != 4 and !(args.len == 5 and (std.mem.eql(u8, mode, "raw") or std.mem.eql(u8, mode, "source")))) return error.Usage;
    const cwd = std.Io.Dir.cwd();

    const input = try cwd.readFileAlloc(io, args[1], arena, .unlimited);

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

    const data = if (args.len == 5) input else blk: {
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
