const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "x264",
    .version = "b35605ac",
    .licenses = &.{"COPYING"},
    .ffmpeg = &.{"libx264"},
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
    const asm_enabled = x86 or arm64;
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
        .HAVE_GETAUXVAL = if (linux and t.abi.isGnu()) @as(?i64, 1) else null,
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
        .HAVE_BITDEPTH10 = 0,
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
        .X264_BIT_DEPTH = 8,
        .X264_CHROMA_FORMAT = 0,
        .X264_VERSION = "",
        .X264_POINTVER = "0.165.x",
    });

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{ "-ffast-math", "-fomit-frame-pointer", "-fvisibility=hidden" }) catch @panic("OOM");
    if (!msvc) flags.appendSlice(b.allocator, &.{ "-std=gnu99", "-D_GNU_SOURCE" }) catch @panic("OOM");
    if (x86) flags.append(b.allocator, "-mstack-alignment=64") catch @panic("OOM");
    const bd_flags = b.allocator.dupe([]const u8, flags.items) catch @panic("OOM");
    const bd8 = std.mem.concat(b.allocator, []const u8, &.{ bd_flags, &.{ "-DHIGH_BIT_DEPTH=0", "-DBIT_DEPTH=8" } }) catch @panic("OOM");

    const mod = c.module(.{});
    mod.addConfigHeader(config);
    mod.addConfigHeader(x264_config);
    mod.addIncludePath(src.path(""));

    var plain: std.ArrayList([]const u8) = .empty;
    var depth: std.ArrayList([]const u8) = .empty;
    plain.appendSlice(b.allocator, &.{ "common/osdep.c", "common/base.c", "common/cpu.c", "common/tables.c", "encoder/api.c" }) catch @panic("OOM");
    depth.appendSlice(b.allocator, &common_depth) catch @panic("OOM");
    depth.append(b.allocator, "common/threadpool.c") catch @panic("OOM");
    if (windows) plain.append(b.allocator, "common/win32thread.c") catch @panic("OOM");
    if (x86) depth.appendSlice(b.allocator, &.{ "common/x86/mc-c.c", "common/x86/predict-c.c" }) catch @panic("OOM");
    if (arm64) depth.appendSlice(b.allocator, &.{ "common/aarch64/asm-offsets.c", "common/aarch64/mc-c.c", "common/aarch64/predict-c.c" }) catch @panic("OOM");

    mod.addCSourceFiles(.{ .root = src.path(""), .files = plain.items, .flags = bd_flags });
    mod.addCSourceFiles(.{ .root = src.path(""), .files = depth.items, .flags = bd8 });

    if (asm_enabled and x86) {
        var asm_flags: std.ArrayList([]const u8) = .empty;
        asm_flags.appendSlice(b.allocator, &.{
            b.fmt("-DARCH_X86_64={d}", .{b10(x86_64)}),
            "-DSTACK_ALIGNMENT=64",
            "-DPIC",
        }) catch @panic("OOM");
        if (prefix) asm_flags.append(b.allocator, "-DPREFIX") catch @panic("OOM");
        const asm_depth = std.mem.concat(b.allocator, []const u8, &.{ asm_flags.items, &.{ "-DBIT_DEPTH=8", "-Dprivate_prefix=x264_8" } }) catch @panic("OOM");
        const inc = &[_]std.Build.LazyPath{ src.path(""), src.path("common/x86") };

        nasm.addFiles(c, mod, .{ .root = src.path(""), .files = &.{"common/x86/cpu-a.asm"}, .include_dirs = inc, .flags = asm_flags.items });
        nasm.addFiles(c, mod, .{
            .root = src.path(""),
            .files = if (x86_64) &x86_64_asm else &x86_32_asm,
            .include_dirs = inc,
            .flags = asm_depth,
        });
        nasm.addFiles(c, mod, .{ .root = src.path(""), .files = &x86_asm, .include_dirs = inc, .flags = asm_depth });
    }
    if (arm64) {
        var s_flags: std.ArrayList([]const u8) = .empty;
        s_flags.appendSlice(b.allocator, &.{ "-DHIGH_BIT_DEPTH=0", "-DBIT_DEPTH=8" }) catch @panic("OOM");
        if (darwin) s_flags.appendSlice(b.allocator, &.{ "-DPREFIX", "-DPIC" }) catch @panic("OOM");
        mod.addCSourceFiles(.{ .root = src.path(""), .files = &aarch64_asm, .flags = s_flags.items });
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
    "common/x86/predict-a.asm",   "common/x86/quant-a.asm", "common/x86/sad-a.asm",
};

const aarch64_asm = [_][]const u8{
    "common/aarch64/dct-a-sve.S",  "common/aarch64/deblock-a-sve.S", "common/aarch64/mc-a-sve.S", "common/aarch64/pixel-a-sve.S",
    "common/aarch64/dct-a-sve2.S", "common/aarch64/bitstream-a.S",   "common/aarch64/cabac-a.S",  "common/aarch64/dct-a.S",
    "common/aarch64/deblock-a.S",  "common/aarch64/mc-a.S",          "common/aarch64/pixel-a.S",  "common/aarch64/predict-a.S",
    "common/aarch64/quant-a.S",
};
