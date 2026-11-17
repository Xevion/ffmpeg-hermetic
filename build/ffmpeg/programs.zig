//! FFmpeg's command-line programs (ffmpeg, ffprobe), linked statically against the archives
//! build/ffmpeg.zig produced. Sources come from fftools/Makefile through gen/ffmpeg/configure.zig;
//! ffplay needs SDL and is not built.
const std = @import("std");
const Ctx = @import("../Ctx.zig");
const config = @import("config.zig");
const resolve = @import("resolve.zig");

pub const Inputs = struct {
    headers: config.Headers,
    /// Directory holding the generated config_components.h and libavutil/ffversion.h.
    gen: std.Build.LazyPath,
    src: *std.Build.Dependency,
    /// Include directories of the external libraries' installed headers.
    includes: []const std.Build.LazyPath,
    /// Flags every FFmpeg C file compiles with.
    flags: []const []const u8,
    embed: *std.Build.Step.Compile,
    /// resource_compression: gzip the embedded resources, as FFmpeg's make rules do.
    compress: bool,
    /// FFmpeg's own archives.
    libs: []const *std.Build.Step.Compile,
    /// External library archives; FFmpeg's archives leave them unresolved.
    deps: []const *std.Build.Step.Compile,
    /// System libraries FFmpeg's and the external libraries' archives need.
    system_libs: []const []const u8,
};

/// The programs this build produces, by fftools name.
const built = [_][]const u8{ "ffmpeg", "ffprobe" };

pub fn add(c: Ctx, in: Inputs) void {
    const b = c.b;
    // Only the libraries define HAVE_AV_CONFIG_H; with it the installed headers drop their version.h.
    var flags: std.ArrayList([]const u8) = .empty;
    for (in.flags) |f| if (!std.mem.eql(u8, f, "-DHAVE_AV_CONFIG_H")) flags.append(b.allocator, f) catch @panic("OOM");
    for (resolve.data.programs) |prog| {
        if (!inList(&built, prog.name)) continue;
        const mod = c.module(.{ .cpp = true });
        mod.addConfigHeader(in.headers.config_h);
        mod.addConfigHeader(in.headers.avconfig_h);
        mod.addIncludePath(in.gen);
        mod.addIncludePath(in.src.path(""));
        for (in.includes) |dir| mod.addIncludePath(dir);
        mod.addCSourceFiles(.{ .root = in.src.path(""), .files = prog.sources, .flags = flags.items });

        for (prog.resources) |res| mod.addCSourceFile(.{ .file = embedResource(c, in, res) });

        for (in.libs) |lib| mod.linkLibrary(lib);
        for (in.deps) |lib| mod.linkLibrary(lib);
        for (in.system_libs) |name| mod.linkSystemLibrary(name, .{});
        // fftools' CommandLineToArgvW, as configure's EXTRALIBS-ffmpeg and EXTRALIBS-ffprobe.
        if (c.isWindows()) mod.linkSystemLibrary("shell32", .{});

        const exe = b.addExecutable(.{ .name = prog.name, .root_module = mod });
        if (c.libc_file) |file| exe.setLibCFile(file);
        b.installArtifact(exe);
    }
}

/// The C array FFmpeg's make rules produce from a `.html` or `.css` resource: minified for CSS,
/// gzipped under resource_compression, named after the file (`graph.css` -> `ff_graph_css_data`).
fn embedResource(c: Ctx, in: Inputs, res: []const u8) std.Build.LazyPath {
    const b = c.b;
    const base = std.fs.path.basename(res);
    const css = std.mem.endsWith(u8, base, ".css");
    if (!css and !std.mem.endsWith(u8, base, ".html")) std.debug.panic("no embedding rule for resource {s}", .{res});
    const run = b.addRunArtifact(in.embed);
    run.addFileArg2(in.src.path(res), .{});
    const out = run.addOutputFileArg2(b.fmt("{s}.c", .{base}), .{});
    const name = b.allocator.dupe(u8, base) catch @panic("OOM");
    std.mem.replaceScalar(u8, name, '.', '_');
    run.addArg(name);
    if (css) run.addArg("minify");
    if (!in.compress) run.addArg("raw");
    return out;
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}
