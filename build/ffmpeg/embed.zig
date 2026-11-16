//! Host tool standing in for FFmpeg's `gzip -nc9` plus `ffbuild/bin2c`: compresses a file into a
//! gzip stream and writes it as `ff_<name>_data[]` and `ff_<name>_len` C definitions.
//! usage: embed <input> <output.c> <name>
const std = @import("std");
const flate = std.compress.flate;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) return error.Usage;
    const cwd = std.Io.Dir.cwd();

    const input = try cwd.readFileAlloc(io, args[1], arena, .unlimited);

    var compressed: std.Io.Writer.Allocating = try .initCapacity(arena, input.len / 4 + 64);
    const window = try arena.alloc(u8, flate.max_window_len);
    var compress = try flate.Compress.init(&compressed.writer, window, .gzip, .best);
    try compress.writer.writeAll(input);
    try compress.finish();
    const data = compressed.written();

    var out: std.Io.Writer.Allocating = try .initCapacity(arena, data.len * 6 + 128);
    try out.writer.print("const unsigned char ff_{s}_data[] = {{ ", .{args[3]});
    for (data) |byte| try out.writer.print("0x{x:0>2}, ", .{byte});
    try out.writer.print("0x00 }};\nconst unsigned int ff_{s}_len = {d};\n", .{ args[3], data.len });
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}
