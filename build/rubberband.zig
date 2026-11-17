const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "rubberband",
    .version = "4.0.0",
    .licenses = &.{"COPYING"},
    .ffmpeg = &.{"librubberband"},
    .license = .gpl,
    .system_libs = .{ .linux = &.{ "m", "pthread" } },
};

/// Rubber Band (C++) with its built-in resampler and, off macOS, its built-in FFT.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const b = c.b;
    const src = c.lazyUpstream("rubberband") orelse return null;
    const t = c.target.result;
    const darwin = t.os.tag.isDarwin();

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{ if (c.isMsvc()) "-std=c++14" else "-std=c++11", "-DUSE_BQRESAMPLER", "-DNO_THREAD_CHECKS", "-DNO_TIMING", "-DNDEBUG" }) catch @panic("OOM");
    flags.append(b.allocator, if (darwin) "-DHAVE_VDSP" else "-DUSE_BUILTIN_FFT") catch @panic("OOM");
    if (c.isWindows()) {
        flags.appendSlice(b.allocator, &.{ "-D_WIN32", "-DNOMINMAX", "-D_USE_MATH_DEFINES" }) catch @panic("OOM");
    } else {
        flags.append(b.allocator, "-DUSE_PTHREADS") catch @panic("OOM");
        flags.append(b.allocator, if (darwin) "-DMALLOC_IS_ALIGNED" else "-DHAVE_POSIX_MEMALIGN") catch @panic("OOM");
    }
    if (t.os.tag != .linux) flags.append(b.allocator, "-DLACK_SINCOS") catch @panic("OOM");

    const mod = c.module(.{ .cpp = true });
    mod.addIncludePath(src.path("rubberband"));
    mod.addIncludePath(src.path("src"));
    mod.addCSourceFiles(.{ .root = src.path(""), .files = &sources, .flags = flags.items });
    // mathmisc.cpp uses size_t without declaring it, which libc++ does not supply transitively.
    const wrapper = b.addWriteFiles().add("mathmisc.cpp", "#include <stddef.h>\n#include \"common/mathmisc.cpp\"\n");
    mod.addCSourceFile(.{ .file = wrapper, .flags = flags.items });
    if (darwin) mod.linkFramework("Accelerate", .{});

    const lib = c.staticLibrary("rubberband", mod);
    for ([_][]const u8{ "rubberband-c.h", "RubberBandStretcher.h", "RubberBandLiveShifter.h" }) |h| {
        lib.installHeader(src.path(b.fmt("rubberband/{s}", .{h})), b.fmt("rubberband/{s}", .{h}));
    }
    return c.single(lib);
}

const sources = [_][]const u8{
    "src/rubberband-c.cpp",
    "src/RubberBandStretcher.cpp",
    "src/RubberBandLiveShifter.cpp",
    "src/faster/AudioCurveCalculator.cpp",
    "src/faster/CompoundAudioCurve.cpp",
    "src/faster/HighFrequencyAudioCurve.cpp",
    "src/faster/SilentAudioCurve.cpp",
    "src/faster/PercussiveAudioCurve.cpp",
    "src/faster/R2Stretcher.cpp",
    "src/faster/StretcherChannelData.cpp",
    "src/faster/StretcherProcess.cpp",
    "src/common/Allocators.cpp",
    "src/common/FFT.cpp",
    "src/common/Log.cpp",
    "src/common/Profiler.cpp",
    "src/common/Resampler.cpp",
    "src/common/StretchCalculator.cpp",
    "src/common/sysutils.cpp",
    "src/common/Thread.cpp",
    "src/finer/R3Stretcher.cpp",
    "src/finer/R3LiveShifter.cpp",
    "src/common/BQResampler.cpp",
};
