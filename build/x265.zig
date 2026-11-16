const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

const version = "4.1";
const api_build = 215;

const Depth = struct {
    bits: u8,
    ns: []const u8,
    /// Only the 8-bit object set exports the C API and dispatches to the others.
    primary: bool,
};

const depths = [_]Depth{
    .{ .bits = 8, .ns = "x265", .primary = true },
    .{ .bits = 10, .ns = "x265_10bit", .primary = false },
    .{ .bits = 12, .ns = "x265_12bit", .primary = false },
};

pub fn build(c: Ctx, nasm: Nasm) *std.Build.Step.Compile {
    const b = c.b;
    const t = c.target.result;
    const src = b.lazyDependency("x265", .{}) orelse
        return c.staticLibrary("x265", c.module(.{ .cpp = true }));
    const x86 = t.cpu.arch.isX86();
    const x86_64 = t.cpu.arch == .x86_64;
    const windows = c.isWindows();
    const darwin = t.os.tag.isDarwin();
    // Win32 x86 and Mach-O asm symbols carry a leading underscore.
    const prefix = darwin or (windows and t.cpu.arch == .x86);

    const config = b.addConfigHeader(.{
        .style = .{ .cmake = src.path("source/x265_config.h.in") },
        .include_path = "x265_config.h",
    }, .{ .X265_BUILD = api_build });

    const mod = c.module(.{ .cpp = true });

    for (depths) |d| {
        const high = d.bits > 8;
        var flags: std.ArrayList([]const u8) = .empty;
        flags.appendSlice(b.allocator, &.{
            "-std=gnu++98",
            "-DNDEBUG",
            "-DHAVE_INT_TYPES_H=1",
            "-D__STDC_LIMIT_MACROS=1",
            "-ffast-math",
            "-fno-exceptions",
            b.fmt("-DHIGH_BIT_DEPTH={d}", .{@intFromBool(high)}),
            b.fmt("-DX265_DEPTH={d}", .{d.bits}),
            b.fmt("-DX265_NS={s}", .{d.ns}),
            b.fmt("-DEXPORT_C_API={d}", .{@intFromBool(d.primary)}),
        }) catch @panic("OOM");
        if (x86) flags.appendSlice(b.allocator, &.{ "-DX265_ARCH_X86=1", "-DENABLE_ASSEMBLY=1", "-mstackrealign" }) catch @panic("OOM");
        if (x86_64) flags.append(b.allocator, "-DX86_64=1") catch @panic("OOM");
        if (x86_64 and !windows) flags.append(b.allocator, "-DPIC") catch @panic("OOM");
        if (darwin) flags.append(b.allocator, "-DMACOS=1") catch @panic("OOM");
        if (windows) flags.append(b.allocator, "-D_WIN32_WINNT=_WIN32_WINNT_WIN7") catch @panic("OOM");
        if (c.isMsvc()) flags.append(b.allocator, "-D_CRT_SECURE_NO_WARNINGS") catch @panic("OOM");

        const linked: []const []const u8 = if (d.primary) &.{ "-DLINKED_10BIT=1", "-DLINKED_12BIT=1" } else &.{};
        const version_flags = std.mem.concat(b.allocator, []const u8, &.{ flags.items, linked, &.{"-DX265_VERSION=" ++ version} }) catch @panic("OOM");
        const api_flags = std.mem.concat(b.allocator, []const u8, &.{ flags.items, linked }) catch @panic("OOM");
        const param_flags = if (windows and c.isMsvc())
            flags.items
        else
            std.mem.concat(b.allocator, []const u8, &.{ flags.items, &.{"-DHAVE_STRTOK_R=1"} }) catch @panic("OOM");

        var groups: std.ArrayList(Group) = .empty;
        groups.appendSlice(b.allocator, &.{
            .{ .files = &common, .flags = flags.items },
            .{ .files = &.{"common/version.cpp"}, .flags = version_flags },
            .{ .files = &.{"common/param.cpp"}, .flags = param_flags },
            .{ .files = &.{"encoder/api.cpp"}, .flags = api_flags },
            .{ .files = &encoder, .flags = flags.items },
        }) catch @panic("OOM");
        if (windows) groups.append(b.allocator, .{ .files = &.{"common/winxp.cpp"}, .flags = flags.items }) catch @panic("OOM");
        if (x86) groups.append(b.allocator, .{ .files = &.{ "common/x86/asm-primitives.cpp", "common/vec/vec-primitives.cpp" }, .flags = flags.items }) catch @panic("OOM");

        const root = src.path("source");
        // COFF cannot link several objects into one, so each source becomes its own object there.
        if (windows) {
            for (groups.items) |g| for (g.files) |file| {
                const fm = c.module(.{ .cpp = true });
                setup(fm, src, config);
                fm.addCSourceFiles(.{ .root = root, .files = &.{file}, .flags = g.flags });
                c.addObjectTo(mod, b.fmt("x265_{d}bit_{s}", .{ d.bits, std.fs.path.stem(file) }), fm);
            };
        } else {
            const m = c.module(.{ .cpp = true });
            setup(m, src, config);
            for (groups.items) |g| m.addCSourceFiles(.{ .root = root, .files = g.files, .flags = g.flags });
            c.addObjectTo(mod, b.fmt("x265_{d}bit", .{d.bits}), m);
        }

        if (x86) {
            const isas = [_]struct { std.Target.x86.Feature, []const u8 }{
                .{ .sse3, "common/vec/dct-sse3.cpp" },
                .{ .ssse3, "common/vec/dct-ssse3.cpp" },
                .{ .sse4_1, "common/vec/dct-sse41.cpp" },
            };
            for (isas) |isa| {
                const im = c.module(.{ .cpp = true, .x86_features = &.{isa[0]} });
                setup(im, src, config);
                im.addCSourceFiles(.{ .root = root, .files = &.{isa[1]}, .flags = flags.items });
                c.addObjectTo(mod, b.fmt("x265_{d}bit_{s}", .{ d.bits, @tagName(isa[0]) }), im);
            }

            var asm_flags: std.ArrayList([]const u8) = .empty;
            asm_flags.appendSlice(b.allocator, &.{
                b.fmt("-DARCH_X86_64={d}", .{@intFromBool(x86_64)}),
                "-DHAVE_ALIGNED_STACK=1",
                b.fmt("-DHIGH_BIT_DEPTH={d}", .{@intFromBool(high)}),
                b.fmt("-DBIT_DEPTH={d}", .{d.bits}),
                b.fmt("-DX265_NS={s}", .{d.ns}),
            }) catch @panic("OOM");
            if (x86_64 and !windows) asm_flags.append(b.allocator, "-DPIC") catch @panic("OOM");
            if (prefix) asm_flags.append(b.allocator, "-DPREFIX") catch @panic("OOM");

            var asm_files: std.ArrayList([]const u8) = .empty;
            asm_files.appendSlice(b.allocator, &asm_common) catch @panic("OOM");
            asm_files.appendSlice(b.allocator, if (high) &asm_high else &asm_8bit) catch @panic("OOM");
            if (!x86_64) asm_files.append(b.allocator, "common/x86/pixel-32.asm") catch @panic("OOM");
            addAsm(c, nasm, mod, d.bits, src.path("source"), src.path("source/common/x86"), asm_files.items, asm_flags.items);
        }
    }

    const lib = c.staticLibrary("x265", mod);
    lib.installHeader(src.path("source/x265.h"), "x265.h");
    lib.installConfigHeader(config);
    return lib;
}

fn setup(m: *std.Build.Module, s: *std.Build.Dependency, cfg: *std.Build.Step.ConfigHeader) void {
    m.addConfigHeader(cfg);
    for ([_][]const u8{ "source", "source/common", "source/encoder" }) |dir| m.addIncludePath(s.path(dir));
}

const Group = struct {
    files: []const []const u8,
    flags: []const []const u8,
};

/// Object names carry the bit depth so the three sets never share an archive member name.
fn addAsm(
    c: Ctx,
    nasm: Nasm,
    into: *std.Build.Module,
    bits: u8,
    root: std.Build.LazyPath,
    include_dir: std.Build.LazyPath,
    files: []const []const u8,
    flags: []const []const u8,
) void {
    for (files) |file| {
        const run = c.b.addRunArtifact(nasm.exe);
        run.addArgs(&.{ "-f", nasm.format });
        run.addDirectoryArg2(include_dir, .{ .prefix = "-I", .suffix = "/" });
        run.addArgs(flags);
        run.addArg("-MD");
        _ = run.addDepFileOutputArg2("obj.d", .{});
        run.addFileArg2(root.path(c.b, file), .{});
        run.addArg("-o");
        into.addObjectFile(run.addOutputFileArg2(c.b.fmt("x265_{d}bit_{s}.o", .{ bits, std.fs.path.stem(file) }), .{}));
    }
}

const common = [_][]const u8{
    "common/bitstream.cpp",  "common/common.cpp",     "common/constants.cpp",
    "common/cpu.cpp",        "common/cudata.cpp",     "common/dct.cpp",
    "common/deblock.cpp",    "common/frame.cpp",      "common/framedata.cpp",
    "common/intrapred.cpp",  "common/ipfilter.cpp",   "common/loopfilter.cpp",
    "common/lowpassdct.cpp", "common/lowres.cpp",     "common/md5.cpp",
    "common/pixel.cpp",      "common/piclist.cpp",    "common/picyuv.cpp",
    "common/predict.cpp",    "common/primitives.cpp", "common/quant.cpp",
    "common/ringmem.cpp",    "common/scaler.cpp",     "common/scalinglist.cpp",
    "common/shortyuv.cpp",   "common/slice.cpp",      "common/temporalfilter.cpp",
    "common/threading.cpp",  "common/threadpool.cpp", "common/wavefront.cpp",
    "common/yuv.cpp",
};

const encoder = [_][]const u8{
    "encoder/analysis.cpp",    "encoder/bitcost.cpp",          "encoder/dpb.cpp",
    "encoder/encoder.cpp",     "encoder/entropy.cpp",          "encoder/frameencoder.cpp",
    "encoder/framefilter.cpp", "encoder/level.cpp",            "encoder/motion.cpp",
    "encoder/nal.cpp",         "encoder/ratecontrol.cpp",      "encoder/reference.cpp",
    "encoder/sao.cpp",         "encoder/search.cpp",           "encoder/sei.cpp",
    "encoder/slicetype.cpp",   "encoder/weightPrediction.cpp",
};

const asm_common = [_][]const u8{
    "common/x86/pixel-a.asm",     "common/x86/const-a.asm",     "common/x86/cpu-a.asm",
    "common/x86/ssd-a.asm",       "common/x86/mc-a.asm",        "common/x86/mc-a2.asm",
    "common/x86/pixel-util8.asm", "common/x86/blockcopy8.asm",  "common/x86/pixeladd8.asm",
    "common/x86/dct8.asm",        "common/x86/seaintegral.asm", "common/x86/loopfilter.asm",
};

const asm_8bit = [_][]const u8{
    "common/x86/sad-a.asm",        "common/x86/intrapred8.asm",  "common/x86/intrapred8_allangs.asm",
    "common/x86/v4-ipfilter8.asm", "common/x86/h-ipfilter8.asm", "common/x86/ipfilter8.asm",
};

const asm_high = [_][]const u8{
    "common/x86/sad16-a.asm",       "common/x86/intrapred16.asm",  "common/x86/v4-ipfilter16.asm",
    "common/x86/h4-ipfilter16.asm", "common/x86/h-ipfilter16.asm", "common/x86/ipfilter16.asm",
};
