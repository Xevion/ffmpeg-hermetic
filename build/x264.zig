const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "x264",
    .version = "b35605ac",
    .licenses = &.{"COPYING"},
    .ffmpeg = &.{"libx264"},
    .ffmpeg_probes = &.{"libx264_hdr10"},
    .license = .gpl,
    .system_libs = .{ .linux = &.{ "m", "pthread" } },
};

pub fn build(c: Ctx, nasm: Nasm) ?Ctx.Output {
    const b = c.b;
    const t = c.target.result;
    const src = c.lazyUpstream("x264") orelse return null;

    const x86 = t.cpu.arch.isX86();
    const x86_64 = t.cpu.arch == .x86_64;
    const arm64 = t.cpu.arch == .aarch64;
    const linux = c.os() == .linux;
    const windows = c.isWindows();
    const darwin = t.os.tag.isDarwin();
    const msvc = c.isMsvc();
    // C callers reach the asm through a leading underscore on these ABIs (x86_64 windows has none).
    const prefix = darwin or (windows and t.cpu.arch == .x86);

    const config = b.addConfigHeader(.{ .include_path = "config.h" }, .{
        .HAVE_MALLOC_H = if (linux) @as(?i64, 1) else null,
        .HAVE_X86_INLINE_ASM = if (x86) @as(?i64, 1) else null,
        .HAVE_MMX = if (x86) @as(?i64, 1) else null,
        .ARCH_X86_64 = if (x86_64) @as(?i64, 1) else null,
        .ARCH_X86 = if (t.cpu.arch == .x86) @as(?i64, 1) else null,
        .ARCH_AARCH64 = if (arm64) @as(?i64, 1) else null,
        .SYS_LINUX = if (linux) @as(?i64, 1) else null,
        .SYS_MACOSX = if (darwin) @as(?i64, 1) else null,
        .SYS_WINDOWS = if (windows) @as(?i64, 1) else null,
        .STACK_ALIGNMENT = @as(i64, if (x86) 64 else 16),
        .HAVE_POSIXTHREAD = b10(!windows),
        .HAVE_CPU_COUNT = if (linux) @as(?i64, 1) else null,
        .HAVE_THREAD = 1,
        .HAVE_SYNC_FETCH_AND_ADD = 1,
        .HAVE_LOG2F = 1,
        .HAVE_STRTOK_R = b10(!msvc),
        .HAVE_CLOCK_GETTIME = b10(!msvc),
        .HAVE_GETAUXVAL = if (linux) @as(?i64, 1) else null,
        .HAVE_SYSCONF = b10(!windows),
        .HAVE_MMAP = if (!windows) @as(?i64, 1) else null,
        .HAVE_THP = if (linux and x86) @as(?i64, 1) else null,
        .HAVE_VECTOREXT = 1,
        .HAVE_BITDEPTH8 = 1,
        .HAVE_GPL = 1,
        .HAVE_INTERLACED = 1,
        .HAVE_ALTIVEC = 0,
        .HAVE_ALTIVEC_H = 0,
        .HAVE_ARMV6 = 0,
        .HAVE_ARMV6T2 = 0,
        .HAVE_NEON = b10(arm64),
        .HAVE_AARCH64 = b10(arm64),
        .HAVE_BEOSTHREAD = 0,
        .HAVE_WIN32THREAD = b10(windows),
        .HAVE_SWSCALE = 0,
        .HAVE_LAVF = 0,
        .HAVE_FFMS = 0,
        .HAVE_GPAC = 0,
        .HAVE_AVS = 0,
        .HAVE_OPENCL = 0,
        .HAVE_LSMASH = 0,
        .HAVE_AS_FUNC = 0,
        .HAVE_INTEL_DISPATCHER = 0,
        .HAVE_MSA = 0,
        .HAVE_LSX = 0,
        .HAVE_WINRT = 0,
        .HAVE_VSX = 0,
        .HAVE_ARM_INLINE_ASM = 0,
        .HAVE_BITDEPTH10 = 1,
        .HAVE_ELF_AUX_INFO = 0,
        .HAVE_DOTPROD = b10(arm64),
        .HAVE_I8MM = b10(arm64),
        .HAVE_SVE = b10(arm64),
        .HAVE_SVE2 = b10(arm64),
        .HAVE_AS_ARCHEXT_DOTPROD_DIRECTIVE = b10(arm64),
        .HAVE_AS_ARCHEXT_I8MM_DIRECTIVE = b10(arm64),
        .HAVE_AS_ARCHEXT_SVE_DIRECTIVE = b10(arm64),
        .HAVE_AS_ARCHEXT_SVE2_DIRECTIVE = b10(arm64),
    });
    if (arm64) config.addIdent("AS_ARCH_LEVEL", "armv8.6-a+crc");
    if (windows) {
        config.addIdent("fseek", if (msvc) "_fseeki64" else "fseeko64");
        config.addIdent("ftell", if (msvc) "_ftelli64" else "ftello64");
    } else {
        config.addIdent("fseek", "fseeko");
        config.addIdent("ftell", "ftello");
    }

    const x264_config = b.addConfigHeader(.{ .include_path = "x264_config.h" }, .{
        .X264_GPL = 1,
        .X264_INTERLACED = 1,
        .X264_BIT_DEPTH = 0,
        .X264_CHROMA_FORMAT = 0,
        .X264_VERSION = "",
        .X264_POINTVER = "0.165.x",
    });

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{ "-ffast-math", "-fomit-frame-pointer", "-fvisibility=hidden" }) catch @panic("OOM");
    if (!msvc) flags.appendSlice(b.allocator, &.{ "-std=gnu99", "-D_GNU_SOURCE" }) catch @panic("OOM");
    if (x86) flags.append(b.allocator, "-mstack-alignment=64") catch @panic("OOM");

    const mod = c.module(.{});
    mod.addConfigHeader(config);
    mod.addConfigHeader(x264_config);
    mod.addIncludePath(src.path(""));

    var plain: std.ArrayList([]const u8) = .empty;
    plain.appendSlice(b.allocator, &.{ "common/osdep.c", "common/base.c", "common/cpu.c", "common/tables.c", "encoder/api.c" }) catch @panic("OOM");
    if (windows) plain.append(b.allocator, "common/win32thread.c") catch @panic("OOM");
    mod.addCSourceFiles(.{ .root = src.path(""), .files = plain.items, .flags = flags.items });

    var common_c: std.ArrayList([]const u8) = .empty;
    common_c.appendSlice(b.allocator, &common_depth) catch @panic("OOM");
    common_c.append(b.allocator, "common/threadpool.c") catch @panic("OOM");
    if (x86) common_c.appendSlice(b.allocator, &.{ "common/x86/mc-c.c", "common/x86/predict-c.c" }) catch @panic("OOM");
    if (arm64) common_c.appendSlice(b.allocator, &.{ "common/aarch64/asm-offsets.c", "common/aarch64/mc-c.c", "common/aarch64/predict-c.c" }) catch @panic("OOM");

    var x86_asm_flags: std.ArrayList([]const u8) = .empty;
    x86_asm_flags.appendSlice(b.allocator, &.{
        b.fmt("-DARCH_X86_64={d}", .{b10(x86_64)}),
        "-DSTACK_ALIGNMENT=64",
        "-DPIC",
    }) catch @panic("OOM");
    if (prefix) x86_asm_flags.append(b.allocator, "-DPREFIX") catch @panic("OOM");
    const x86_inc = &[_]std.Build.LazyPath{ src.path(""), src.path("common/x86") };
    if (x86) nasm.addFiles(c, mod, .{ .root = src.path(""), .files = &.{"common/x86/cpu-a.asm"}, .include_dirs = x86_inc, .flags = x86_asm_flags.items });

    const setup: Ctx.Setup = .{
        .includes = &.{src.path("")},
        .config_headers = &.{ config, x264_config },
    };
    for ([_]u8{ 8, 10 }) |bits| {
        const high = bits > 8;
        const depth_flags = std.mem.concat(b.allocator, []const u8, &.{
            flags.items,
            &.{ b.fmt("-DHIGH_BIT_DEPTH={d}", .{b10(high)}), b.fmt("-DBIT_DEPTH={d}", .{bits}) },
        }) catch @panic("OOM");
        var groups: std.ArrayList(Ctx.SourceGroup) = .empty;
        groups.append(b.allocator, .{ .root = src.path(""), .files = common_c.items, .flags = depth_flags }) catch @panic("OOM");

        if (arm64) {
            var s_flags: std.ArrayList([]const u8) = .empty;
            s_flags.appendSlice(b.allocator, &.{ b.fmt("-DHIGH_BIT_DEPTH={d}", .{b10(high)}), b.fmt("-DBIT_DEPTH={d}", .{bits}) }) catch @panic("OOM");
            if (darwin) s_flags.appendSlice(b.allocator, &.{ "-DPREFIX", "-DPIC" }) catch @panic("OOM");
            groups.append(b.allocator, .{ .root = src.path(""), .files = &aarch64_asm, .flags = s_flags.items }) catch @panic("OOM");
        }
        c.addSources(mod, b.fmt("x264_{d}bit", .{bits}), .{ .setup = setup, .groups = groups.items });

        if (x86) {
            const asm_flags = std.mem.concat(b.allocator, []const u8, &.{
                x86_asm_flags.items,
                &.{ b.fmt("-DBIT_DEPTH={d}", .{bits}), b.fmt("-Dprivate_prefix=x264_{d}", .{bits}) },
            }) catch @panic("OOM");
            var files: std.ArrayList([]const u8) = .empty;
            files.appendSlice(b.allocator, if (x86_64) &x86_64_asm else &x86_32_asm) catch @panic("OOM");
            files.appendSlice(b.allocator, &x86_asm) catch @panic("OOM");
            files.append(b.allocator, if (high) "common/x86/sad16-a.asm" else "common/x86/sad-a.asm") catch @panic("OOM");
            nasm.addFiles(c, mod, .{
                .root = src.path(""),
                .files = files.items,
                .include_dirs = x86_inc,
                .flags = asm_flags,
                .object_prefix = b.fmt("x264_{d}bit_", .{bits}),
            });
        }
    }

    const lib = c.staticLibrary("x264", mod);
    lib.installHeader(src.path("x264.h"), "x264.h");
    lib.installConfigHeader(x264_config);
    return c.single(lib);
}

fn b10(v: bool) u1 {
    return @intFromBool(v);
}

const common_depth = [_][]const u8{
    "common/mc.c",       "common/predict.c", "common/pixel.c",        "common/macroblock.c", "common/frame.c",
    "common/dct.c",      "common/cabac.c",   "common/common.c",       "common/rectangle.c",  "common/set.c",
    "common/quant.c",    "common/deblock.c", "common/vlc.c",          "common/mvpred.c",     "common/bitstream.c",
    "encoder/analyse.c", "encoder/me.c",     "encoder/ratecontrol.c", "encoder/set.c",       "encoder/macroblock.c",
    "encoder/cabac.c",   "encoder/cavlc.c",  "encoder/encoder.c",     "encoder/lookahead.c",
};

const x86_64_asm = [_][]const u8{ "common/x86/dct-64.asm", "common/x86/trellis-64.asm" };
const x86_32_asm = [_][]const u8{ "common/x86/dct-32.asm", "common/x86/pixel-32.asm" };

const x86_asm = [_][]const u8{
    "common/x86/bitstream-a.asm", "common/x86/const-a.asm", "common/x86/cabac-a.asm", "common/x86/dct-a.asm",
    "common/x86/deblock-a.asm",   "common/x86/mc-a.asm",    "common/x86/mc-a2.asm",   "common/x86/pixel-a.asm",
    "common/x86/predict-a.asm",   "common/x86/quant-a.asm",
};

const aarch64_asm = [_][]const u8{
    "common/aarch64/dct-a-sve.S",  "common/aarch64/deblock-a-sve.S", "common/aarch64/mc-a-sve.S", "common/aarch64/pixel-a-sve.S",
    "common/aarch64/dct-a-sve2.S", "common/aarch64/bitstream-a.S",   "common/aarch64/cabac-a.S",  "common/aarch64/dct-a.S",
    "common/aarch64/deblock-a.S",  "common/aarch64/mc-a.S",          "common/aarch64/pixel-a.S",  "common/aarch64/predict-a.S",
    "common/aarch64/quant-a.S",
};
