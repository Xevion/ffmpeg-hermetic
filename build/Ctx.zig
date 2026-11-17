//! Shared settings for every library in the graph: one target, one optimize mode.
const std = @import("std");
const Ctx = @This();

const LazyPath = std.Build.LazyPath;

b: *std.Build,
target: std.Build.ResolvedTarget,
optimize: std.builtin.Optimize,
/// Builds the GPL codecs (x264, x265) and FFmpeg's GPL configuration.
gpl: bool = false,
/// Omits debug info from every object.
strip: ?bool = null,
/// What each library built so far produced, by registry name.
built: *Built,
/// Directory of an xwin splat (MSVC CRT plus Windows SDK), for msvc targets off Windows.
winsdk: ?[]const u8 = null,
/// Libc description set on every compile step this Ctx creates; only msvc targets with `winsdk` have one.
libc_file: ?LazyPath = null,

pub const Built = std.StringHashMapUnmanaged(Output);

/// One static archive of a package.
pub const Archive = struct {
    lib: *std.Build.Step.Compile,
    /// Archives of the same package this one needs after it on the link line.
    links: []const []const u8 = &.{},
    /// False for archives FFmpeg never links, which a bundle leaves out.
    bundled: bool = true,
};

/// What a package gives its dependents: its archives and its installed include tree.
pub const Output = struct {
    /// Empty for header-only packages.
    archives: []const Archive,
    include: LazyPath,
};

/// The output of an already built library, for linking or reading its installed headers.
pub fn dep(c: Ctx, name: []const u8) Output {
    return c.built.get(name) orelse std.debug.panic("{s} is not built yet; list it in `needs`", .{name});
}

/// A package of one archive that carries all of its installed headers.
pub fn single(c: Ctx, lib: *std.Build.Step.Compile) Output {
    return c.package(&.{.{ .lib = lib }});
}

/// A package of several archives. The first archive carries every installed header.
pub fn package(c: Ctx, archives: []const Archive) Output {
    return .{
        .archives = c.b.allocator.dupe(Archive, archives) catch @panic("OOM"),
        .include = archives[0].lib.getEmittedIncludeTree(),
    };
}

/// A header-only package: no archive, only the `.h` files of `dirs` (sub path, source) in one include tree.
pub fn headerOnly(c: Ctx, dirs: []const struct { []const u8, LazyPath }) Output {
    const wf = c.b.addWriteFiles();
    for (dirs) |d| _ = wf.addCopyDirectory(d[1], d[0], .{ .include_extensions = &.{".h"} });
    return .{ .archives = &.{}, .include = wf.getDirectory() };
}

pub fn os(c: Ctx) std.Target.Os.Tag {
    return c.target.result.os.tag;
}

pub fn arch(c: Ctx) std.Target.Cpu.Arch {
    return c.target.result.cpu.arch;
}

pub fn isWindows(c: Ctx) bool {
    return c.os() == .windows;
}

pub fn isMsvc(c: Ctx) bool {
    return c.target.result.abi == .msvc;
}

/// The unpacked upstream tarball pinned in build.zig.zon under `name`.
pub fn upstream(c: Ctx, name: []const u8) *std.Build.Dependency {
    return c.b.dependency(name, .{});
}

/// Like `upstream` for a lazy dependency; null until it is fetched, and the library is skipped.
pub fn lazyUpstream(c: Ctx, name: []const u8) ?*std.Build.Dependency {
    return c.b.lazyDependency(name, .{});
}

pub const ModuleOptions = struct {
    cpp: bool = false,
    /// Extra CPU features, for sources upstream builds with `-msse4.1` and the like behind
    /// runtime dispatch. Zig takes features from the target, so per-file `-m` flags are ignored.
    x86_features: []const std.Target.x86.Feature = &.{},
    aarch64_features: []const std.Target.aarch64.Feature = &.{},
};

/// A C (or C++) module for one static library.
pub fn module(c: Ctx, opts: ModuleOptions) *std.Build.Module {
    var target = c.target;
    if (opts.x86_features.len > 0 or opts.aarch64_features.len > 0) {
        var q = c.target.query;
        for (opts.x86_features) |f| q.cpu_features_add.addFeature(@backingInt(f));
        for (opts.aarch64_features) |f| q.cpu_features_add.addFeature(@backingInt(f));
        target = c.b.resolveTargetQuery(q);
    }
    const m = c.b.createModule(.{
        .target = target,
        .optimize = c.optimize,
        .link_libc = true,
        // msvc C++ uses the MSVC STL from the CRT include directory; zig cannot build libc++abi there.
        .link_libcpp = if (opts.cpp and !c.isMsvc()) true else null,
        .pic = true,
        .strip = c.strip,
        // Upstream code relies on behavior UBSan traps on, and configure probes never see it.
        .sanitize_c = .off,
    });
    if (c.isMsvc()) for ([_][]const u8{ "_CRT_SECURE_NO_WARNINGS", "_CRT_NONSTDC_NO_WARNINGS" }) |name| m.addCMacro(name, "1");
    if (c.winsdk) |sdk| if (c.isMsvc()) for ([_][]const u8{ "um", "shared" }) |dir| {
        m.addSystemIncludePath(.{ .cwd_relative = c.b.pathJoin(&.{ sdk, "sdk/include", dir }) });
    };
    return m;
}

/// The directory name xwin uses for `arch` under crt/lib and sdk/lib.
fn winsdkArch(arch_tag: std.Target.Cpu.Arch) []const u8 {
    return switch (arch_tag) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "x86",
        else => std.debug.panic("no xwin library directory for {s}", .{@tagName(arch_tag)}),
    };
}

/// A libc description pointing at the xwin splat, for msvc targets when `winsdk` is set. Native
/// Windows hosts leave `winsdk` unset and zig finds the installed MSVC and SDK itself. Computed
/// once and stored in `libc_file` before any library is declared.
pub fn winsdkLibcFile(c: Ctx) ?LazyPath {
    if (!c.isMsvc()) return null;
    const sdk = c.winsdk orelse {
        if (c.b.graph.host.result.os.tag != .windows) std.process.fatal(
            "msvc targets need an MSVC CRT and Windows SDK off Windows: pass -Dwinsdk=<xwin splat directory>",
            .{},
        );
        return null;
    };
    const arch_dir = winsdkArch(c.arch());
    const text = c.b.fmt(
        \\include_dir={0s}/sdk/include/ucrt
        \\sys_include_dir={0s}/crt/include
        \\crt_dir={0s}/sdk/lib/ucrt/{1s}
        \\msvc_lib_dir={0s}/crt/lib/{1s}
        \\kernel32_lib_dir={0s}/sdk/lib/um/{1s}
        \\cc_dir=
        \\darwin_sdk_dir=
        \\
    , .{ sdk, arch_dir });
    return c.b.addWriteFiles().add("msvc-libc.txt", text);
}

fn withLibc(c: Ctx, compile: *std.Build.Step.Compile) *std.Build.Step.Compile {
    if (c.libc_file) |file| compile.setLibCFile(file);
    return compile;
}

/// A static library of `root_module`; every library and object goes through here so it gets `libc_file`.
pub fn staticLibrary(c: Ctx, name: []const u8, root_module: *std.Build.Module) *std.Build.Step.Compile {
    return c.withLibc(c.b.addLibrary(.{ .name = name, .linkage = .static, .root_module = root_module }));
}

/// An object file of `root_module`, for linking into another module.
pub fn object(c: Ctx, name: []const u8, root_module: *std.Build.Module) *std.Build.Step.Compile {
    return c.withLibc(c.b.addObject(.{ .name = name, .root_module = root_module }));
}

/// `dirs` under `root` as include paths; an empty name is `root` itself.
pub fn includeDirs(c: Ctx, root: LazyPath, dirs: []const []const u8) []const LazyPath {
    const out = c.b.allocator.alloc(LazyPath, dirs.len) catch @panic("OOM");
    for (out, dirs) |*path, dir| path.* = if (dir.len == 0) root else root.path(c.b, dir);
    return out;
}

/// What a module needs to find its headers.
pub const Setup = struct {
    includes: []const LazyPath = &.{},
    config_headers: []const *std.Build.Step.ConfigHeader = &.{},

    pub fn apply(s: Setup, m: *std.Build.Module) void {
        for (s.config_headers) |header| m.addConfigHeader(header);
        for (s.includes) |dir| m.addIncludePath(dir);
    }

    fn isEmpty(s: Setup) bool {
        return s.includes.len == 0 and s.config_headers.len == 0;
    }
};

/// Source files that share one root and one set of compiler flags.
pub const SourceGroup = struct {
    root: LazyPath,
    files: []const []const u8,
    flags: []const []const u8 = &.{},
};

/// Adds every group's files to `m` as C sources of that module.
pub fn addGroups(m: *std.Build.Module, groups: []const SourceGroup) void {
    for (groups) |g| m.addCSourceFiles(.{ .root = g.root, .files = g.files, .flags = g.flags });
}

pub const SourceOptions = struct {
    /// CPU features and language for the module the sources compile in.
    module: ModuleOptions = .{},
    /// Headers the sources need beyond what `into` already has.
    setup: Setup = .{},
    groups: []const SourceGroup,
};

/// Compiles sources into `into`. Sources that need the parent's own module (no extra CPU features,
/// same language, no extra headers) are added to it directly. Otherwise they compile in a module
/// of their own: on ELF one object named `name` holding every file, elsewhere one object per
/// file. COFF cannot merge compiled files into one object, and Mach-O merging turns
/// hidden-visibility symbols local, so code in one merged object could not be called from another.
pub fn addSources(c: Ctx, into: *std.Build.Module, name: []const u8, o: SourceOptions) void {
    if (c.sharesModule(into, o)) return addGroups(into, o.groups);
    if (c.target.result.ofmt == .elf) {
        const m = c.module(o.module);
        o.setup.apply(m);
        addGroups(m, o.groups);
        into.addObject(c.object(name, m));
        return;
    }
    for (o.groups) |g| for (g.files) |file| {
        const m = c.module(o.module);
        o.setup.apply(m);
        m.addCSourceFiles(.{ .root = g.root, .files = &.{file}, .flags = g.flags });
        const stem = file[0 .. file.len - std.fs.path.extension(file).len];
        const object_name = c.b.fmt("{s}_{s}", .{ name, stem });
        std.mem.replaceScalar(u8, object_name, '/', '_');
        into.addObject(c.object(object_name, m));
    };
}

fn sharesModule(c: Ctx, into: *std.Build.Module, o: SourceOptions) bool {
    if (o.module.x86_features.len > 0 or o.module.aarch64_features.len > 0 or !o.setup.isEmpty()) return false;
    // msvc modules never link libc++, so the language makes no difference there.
    return c.isMsvc() or o.module.cpp == (into.link_libcpp orelse false);
}
