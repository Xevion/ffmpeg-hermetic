const std = @import("std");
const Ctx = @import("build/Ctx.zig");
const Nasm = @import("build/Nasm.zig");
const Meta = @import("build/Meta.zig");
const ffmpeg = @import("build/ffmpeg.zig");
const bundle = @import("build/bundle.zig");

/// Every library. Each module exports `meta` and `build(c, nasm) ?Ctx.Output`, null while a lazy dependency is not fetched.
const ports = .{
    @import("build/zlib.zig"),
    @import("build/opus.zig"),
    @import("build/lame.zig"),
    @import("build/kvazaar.zig"),
    @import("build/dav1d.zig"),
    @import("build/openh264.zig"),
    @import("build/svt_av1.zig"),
    @import("build/libaom.zig"),
    @import("build/libvpx.zig"),
    @import("build/x264.zig"),
    @import("build/x265.zig"),
    @import("build/libogg.zig"),
    @import("build/libvorbis.zig"),
    @import("build/libwebp.zig"),
    @import("build/openjpeg.zig"),
    @import("build/libtheora.zig"),
    @import("build/soxr.zig"),
    @import("build/zimg.zig"),
    @import("build/bzip2.zig"),
    @import("build/xz.zig"),
    @import("build/freetype.zig"),
    @import("build/fribidi.zig"),
    @import("build/harfbuzz.zig"),
    @import("build/libass.zig"),
    @import("build/highway.zig"),
    @import("build/brotli.zig"),
    @import("build/libjxl.zig"),
    @import("build/speex.zig"),
    @import("build/twolame.zig"),
    @import("build/libgsm.zig"),
    @import("build/snappy.zig"),
    @import("build/libxml2.zig"),
    @import("build/vvenc.zig"),
    @import("build/vvdec.zig"),
    @import("build/libvmaf.zig"),
    @import("build/xvidcore.zig"),
    @import("build/vidstab.zig"),
    @import("build/rubberband.zig"),
    @import("build/openssl.zig"),
    @import("build/vulkan_headers.zig"),
    @import("build/amf.zig"),
    @import("build/libvpl.zig"),
    @import("build/opencl_headers.zig"),
    @import("build/opencl.zig"),
    @import("build/nv_codec_headers.zig"),
    @import("build/libdrm.zig"),
    @import("build/libva.zig"),
};

const Library = struct {
    meta: Meta,
    build: *const fn (Ctx, Nasm) ?Ctx.Output,
    sources: []const Meta.Source,
};

const libraries = blk: {
    @setEvalBranchQuota(100_000);
    var out: [ports.len]Library = undefined;
    for (ports, 0..) |port, i| {
        out[i] = .{ .meta = port.meta, .build = port.build, .sources = Meta.sources(port.meta) };
    }
    for (out, 0..) |lib, i| {
        for (out[0..i]) |other| if (std.mem.eql(u8, lib.meta.name, other.meta.name)) {
            @compileError("library " ++ lib.meta.name ++ " is registered twice");
        };
        for (lib.meta.needs) |need| {
            const earlier = for (out[0..i]) |other| {
                if (std.mem.eql(u8, need, other.meta.name)) break true;
            } else false;
            if (!earlier) @compileError(lib.meta.name ++ " needs " ++ need ++ ", which is not registered before it");
        }
    }
    break :blk out;
};

/// What the command line asked for.
const Selection = struct {
    /// `-D<name>` per library; null when not passed.
    wanted: [libraries.len]?bool,
    /// `-Donly=<name>`.
    only: ?[]const u8,
    version3: bool,
};

fn find(name: []const u8) *const Library {
    for (&libraries) |*lib| if (std.mem.eql(u8, lib.meta.name, name)) return lib;
    std.debug.panic("unknown library {s}", .{name});
}

fn index(lib: *const Library) usize {
    for (&libraries, 0..) |*other, i| if (other == lib) return i;
    unreachable;
}

/// Why `lib` itself is not built with these options on this target, or null.
fn ownReason(c: Ctx, sel: Selection, lib: *const Library) ?[]const u8 {
    const m = lib.meta;
    if (sel.wanted[index(lib)] == false) return c.b.fmt("-D{s}=false", .{m.name});
    switch (m.license) {
        .lgpl => {},
        .gpl => if (!c.gpl) return "needs -Dgpl",
        .gpl_needs_version3 => if (c.gpl and !sel.version3) return "needs -Dversion3 in a GPL build",
    }
    if (!m.supports(c)) return c.b.fmt("not supported on {t}-{t}", .{ c.arch(), c.os() });
    return null;
}

/// Why a library `lib` needs is not built, or null. A library whose needs are unbuilt is itself unbuilt.
fn needReason(c: Ctx, sel: Selection, lib: *const Library) ?[]const u8 {
    for (lib.meta.needs) |name| {
        const need = find(name);
        const why = ownReason(c, sel, need) orelse needReason(c, sel, need) orelse continue;
        return c.b.fmt("needs {s} ({s})", .{ name, why });
    }
    return null;
}

/// Builds `lib` once, after the libraries it needs, and records its output in `c.built`. False
/// when it or a library it needs waits on a lazy dependency.
fn buildLibrary(c: Ctx, nasm: Nasm, lib: *const Library, out: *std.ArrayList(Meta.Built)) bool {
    const name = lib.meta.name;
    if (c.built.contains(name)) return true;
    for (lib.meta.needs) |need| if (!buildLibrary(c, nasm, find(need), out)) return false;
    const built = lib.build(c, nasm) orelse return false;
    c.built.put(c.b.allocator, name, built) catch @panic("OOM");
    if (built.archives.len == 0) {
        c.b.installDirectory(.{ .source_dir = built.include, .install_dir = .header, .install_subdir = "" });
    }
    for (built.archives) |archive| c.b.installArtifact(archive.lib);
    out.append(c.b.allocator, .{ .meta = &lib.meta, .sources = lib.sources, .output = built }) catch @panic("OOM");
    return true;
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    var c: Ctx = .{
        .b = b,
        .target = b.standardTargetOptions(.{}),
        .optimize = optimize,
        .gpl = b.option(bool, "gpl", "Build x264, x265 and FFmpeg's GPL configuration") orelse false,
        .strip = b.option(bool, "strip", "Omit debug info (default: on unless Debug)") orelse (optimize != .debug),
        .built = b.allocator.create(Ctx.Built) catch @panic("OOM"),
        .winsdk = if (b.option([]const u8, "winsdk", "xwin splat directory (MSVC CRT + Windows SDK) for msvc targets off Windows")) |dir| b.pathResolve(&.{dir}) else null,
    };
    c.built.* = .empty;
    c.libc_file = c.winsdkLibcFile();
    const only = b.option([]const u8, "only", "Build a single library (zlib, opus, dav1d, ..., ffmpeg)");
    const nasm = Nasm.init(c);
    const with_ffmpeg = if (only) |name| std.mem.eql(u8, name, "ffmpeg") else b.option(bool, "ffmpeg", "Build FFmpeg on top of the libraries (default: true)") orelse true;

    const version3 = b.option(bool, "version3", "Use FFmpeg's (L)GPL version 3 licensing, which admits OpenSSL 3 in GPL builds") orelse false;
    const ffmpeg_version = b.option(ffmpeg.Version, "ffmpeg-version", "FFmpeg release to build (default: 8.1)") orelse .@"8.1";
    const programs = b.option(bool, "programs", "Also build the ffmpeg and ffprobe programs (needs the ffmpeg graph)") orelse false;
    var sel: Selection = .{ .wanted = undefined, .only = only, .version3 = version3 };
    for (&libraries, &sel.wanted) |*lib, *wanted| {
        wanted.* = b.option(bool, lib.meta.name, b.fmt("Build {s} and enable it in FFmpeg (default: true)", .{lib.meta.name}));
    }

    var deps: std.ArrayList(Meta.Built) = .empty;
    for (&libraries) |*lib| {
        const name = lib.meta.name;
        if (ownReason(c, sel, lib) != null) continue;
        if (only) |only_name| if (!with_ffmpeg and !std.mem.eql(u8, only_name, name)) continue;
        if (needReason(c, sel, lib)) |why| {
            const requested = sel.wanted[index(lib)] == true or (only != null and std.mem.eql(u8, only.?, name));
            if (requested) std.process.fatal("{s} was requested but {s}", .{ name, why });
            std.log.warn("{s} is not built: {s}", .{ name, why });
            continue;
        }
        _ = buildLibrary(c, nasm, lib, &deps);
    }
    if (with_ffmpeg) {
        var enabled: std.ArrayList([]const u8) = .empty;
        for (&libraries) |*lib| if (c.built.contains(lib.meta.name)) enabled.appendSlice(b.allocator, lib.meta.ffmpeg) catch @panic("OOM");
        var probes: std.ArrayList(ffmpeg.Probe) = .empty;
        for (&libraries) |*lib| {
            if (lib.meta.ffmpeg_probes.len > 0) probes.append(b.allocator, .{ .names = lib.meta.ffmpeg_probes, .found = c.built.contains(lib.meta.name) }) catch @panic("OOM");
        }
        const ff = ffmpeg.build(c, nasm, deps.items, .{ .libraries = enabled.items, .probes = probes.items, .version3 = version3, .programs = programs, .version = ffmpeg_version });
        for (ff.libs) |artifact| b.installArtifact(artifact);
        if (ff.libs.len > 0) bundle.add(c, ffmpeg_version, version3, deps.items, ff.libs, ff.programs);
    }
}
