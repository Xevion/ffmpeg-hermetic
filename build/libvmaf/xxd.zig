//! Host tool standing in for `xxd -i -n <name>`: writes a file as `unsigned char <name>[]` and
//! `unsigned int <name>_len` C definitions.
//! usage: xxd <input> <output.c> <name>
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) return error.Usage;
    const cwd = std.Io.Dir.cwd();

    const input = try cwd.readFileAlloc(io, args[1], arena, .unlimited);
    var out: std.Io.Writer.Allocating = try .initCapacity(arena, input.len * 6 + 128);
    try out.writer.print("unsigned char {s}[] = {{", .{args[3]});
    for (input, 0..) |byte, i| {
        try out.writer.writeAll(if (i % 12 == 0) "\n " else " ");
        try out.writer.print("0x{x:0>2}{s}", .{ byte, if (i + 1 == input.len) "" else "," });
    }
    try out.writer.print("\n}};\nunsigned int {s}_len = {d};\n", .{ args[3], input.len });
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.written() });
}
