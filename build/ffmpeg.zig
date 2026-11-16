//! FFmpeg's seven libraries, compiled from the source lists tools/ffmpeg_extract.py captured.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const config = @import("ffmpeg/config.zig");
const Sources = @import("ffmpeg/Sources.zig");

const lgpl = @import("../gen/ffmpeg/x86_64-linux-lgpl/sources.zig");
const gpl = @import("../gen/ffmpeg/x86_64-linux-gpl/sources.zig");

/// Static libraries in link order: each depends only on those after it.
pub const link_order = [_][]const u8{ "avdevice", "avfilter", "avformat", "avcodec", "swresample", "swscale", "avutil" };

pub fn build(c: Ctx, nasm: Nasm, deps: []const *std.Build.Step.Compile) []const *std.Build.Step.Compile {
    const b = c.b;
    const t = c.target.result;
    if (!(t.cpu.arch == .x86_64 and t.os.tag == .linux)) {
        std.debug.panic("FFmpeg sources are only extracted for x86_64-linux so far, not {s}", .{@tagName(t.os.tag)});
    }
    const src = c.upstream("ffmpeg");
    const gen = b.path(if (c.gpl) "gen/ffmpeg/x86_64-linux-gpl" else "gen/ffmpeg/x86_64-linux-lgpl");
    const libraries: []const Sources.Library = if (c.gpl) &gpl.libraries else &lgpl.libraries;
    const headers = config.add(c, .{ .gpl = c.gpl });
    const embed = b.addExecutable(.{
        .name = "embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/ffmpeg/embed.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });

    var dep_includes: std.ArrayList(std.Build.LazyPath) = .empty;
    for (deps) |dep| {
        const tree = dep.getEmittedIncludeTree();
        dep_includes.append(b.allocator, tree) catch @panic("OOM");
        for ([_][]const u8{ "opus", "svt-av1", "libdrm" }) |sub| {
            dep_includes.append(b.allocator, tree.path(b, sub)) catch @panic("OOM");
        }
    }
    dep_includes.append(b.allocator, c.upstream("nv_codec_headers").path("include")) catch @panic("OOM");

    for ([_]struct { *std.Build.Step.ConfigHeader, []const u8 }{
        .{ headers.config_h, "config.h" },
        .{ headers.config_asm, "config.asm" },
        .{ headers.avconfig_h, "libavutil/avconfig.h" },
    }) |entry| {
        b.getInstallStep().dependOn(&b.addInstallFile(entry[0].getOutputFile(), b.fmt("share/ffmpeg-zig/config/{s}", .{entry[1]})).step);
    }

    var out: std.ArrayList(*std.Build.Step.Compile) = .empty;
    for (libraries) |lib| {
        var flags: std.ArrayList([]const u8) = .empty;
        flags.appendSlice(b.allocator, &common_flags) catch @panic("OOM");
        flags.append(b.allocator, b.fmt("-DBUILDING_{s}", .{lib.name})) catch @panic("OOM");
        if (t.cpu.arch.isX86()) flags.append(b.allocator, "-mstack-alignment=16") catch @panic("OOM");

        const mod = c.module(.{});
        for (lib.c, 0..) |group, i| {
            const m = if (group.includes.len == 0) mod else c.module(.{});
            m.addConfigHeader(headers.config_h);
            m.addConfigHeader(headers.avconfig_h);
            m.addIncludePath(gen);
            m.addIncludePath(src.path(""));
            for (group.includes) |dir| m.addIncludePath(src.path(dir));
            for (dep_includes.items) |dir| m.addIncludePath(dir);
            m.addCSourceFiles(.{ .root = src.path(""), .files = group.files, .flags = flags.items });
            if (m != mod) c.addObjectTo(mod, b.fmt("{s}_group{d}", .{ lib.name, i }), m);
        }

        if (lib.nasm.len > 0) {
            nasm.addFiles(c, mod, .{
                .root = src.path(""),
                .files = lib.nasm,
                .include_dirs = &.{ gen, src.path(""), src.path(b.fmt("lib{s}/x86", .{lib.name})) },
                .preincludes = &.{headers.config_asm.getOutputFile()},
            });
        }

        for (lib.cuda) |cu| addCuda(c, mod, src, embed, cu);

        const artifact = c.staticLibrary(lib.name, mod);
        for (lib.headers) |h| {
            if (std.mem.eql(u8, h, "avconfig.h") or std.mem.eql(u8, h, "ffversion.h")) continue;
            artifact.installHeader(src.path(b.fmt("lib{s}/{s}", .{ lib.name, h })), b.fmt("lib{s}/{s}", .{ lib.name, h }));
        }
        if (std.mem.eql(u8, lib.name, "avutil")) {
            artifact.installConfigHeader(headers.avconfig_h);
            artifact.installHeader(gen.path(b, "libavutil/ffversion.h"), "libavutil/ffversion.h");
        }
        out.append(b.allocator, artifact) catch @panic("OOM");
    }
    return out.items;
}

/// `.cu` -> PTX with zig's own clang, then gzip and embed as C, as FFmpeg's make rules do.
fn addCuda(c: Ctx, mod: *std.Build.Module, src: *std.Build.Dependency, embed: *std.Build.Step.Compile, cu: []const u8) void {
    const b = c.b;
    const stem = std.fs.path.stem(cu);
    const ptx = b.addSystemCommand(&.{ b.graph.zig_exe, "clang", "-x", "cuda" });
    ptx.addArgs(&.{
        "--cuda-gpu-arch=sm_30", "-O2",        "-std=c++11",         "-m64",                 "-S",
        "-nocudalib",            "-nocudainc", "--cuda-device-only", "-Wno-c++11-narrowing",
    });
    ptx.addArg("-include");
    ptx.addFileArg2(src.path("compat/cuda/cuda_runtime.h"), .{});
    ptx.addDirectoryArg2(src.path(""), .{ .prefix = "-I" });
    ptx.addArg("-o");
    const ptx_file = ptx.addOutputFileArg2(b.fmt("{s}.ptx", .{stem}), .{});
    ptx.addFileArg2(src.path(cu), .{});

    const run = b.addRunArtifact(embed);
    run.addFileArg2(ptx_file, .{});
    const c_file = run.addOutputFileArg2(b.fmt("{s}.ptx.c", .{stem}), .{});
    run.addArg(b.fmt("{s}_ptx", .{stem}));
    mod.addCSourceFile(.{ .file = c_file });
}

const common_flags = [_][]const u8{
    "-D_ISOC11_SOURCE",
    "-D_FILE_OFFSET_BITS=64",
    "-D_LARGEFILE_SOURCE",
    "-D_POSIX_C_SOURCE=200112",
    "-D_XOPEN_SOURCE=600",
    "-DPIC",
    "-DZLIB_CONST",
    "-DHAVE_AV_CONFIG_H",
    "-std=c17",
    "-fomit-frame-pointer",
    "-fno-math-errno",
    "-fno-signed-zeros",
};
