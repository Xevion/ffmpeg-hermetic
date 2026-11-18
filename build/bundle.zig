//! The `bundle` step: libc++ and libc++abi built from zig's bundled sources, then every archive,
//! FFmpeg's headers and a MANIFEST.json packed into a bundle directory and `.tar.zst`.
const std = @import("std");
const builtin = @import("builtin");
const Ctx = @import("Ctx.zig");
const Meta = @import("Meta.zig");
const ff = @import("ffmpeg.zig");
const config = @import("ffmpeg/config.zig");

const Compile = std.Build.Step.Compile;

const Link = struct { name: []const u8, kind: []const u8 };
const SourceEntry = struct { name: []const u8, version: []const u8, sha256: []const u8, url: []const u8 };

const Spec = struct {
    variant: []const u8,
    ffmpeg_version: []const u8,
    bundle_rev: u32,
    target: []const u8,
    glibc_floor: []const u8,
    /// Last part of the bundle's name, after the variant.
    suffix: []const u8,
    zig: []const u8,
    link: []const Link,
    sources: []const SourceEntry,
};

/// One archive of a built package, placed on the link line by `linkOrder`.
const Node = struct {
    lib: *Compile,
    /// Index of its package in the registry-ordered build list.
    package: usize,
    links: []const []const u8,
};

/// Adds the `bundle` and `bundle-check` steps. `built` is every library that was built, in
/// registry order, and `ffmpeg` the FFmpeg libraries whose installed headers become the bundle's
/// include directory. `programs` (ffmpeg, ffprobe) go into a second archive beside the bundle.
pub fn add(c: Ctx, version: ff.Version, built: []const Meta.Built, ffmpeg: []const *Compile, programs: []const *Compile) void {
    const b = c.b;
    const t = c.target.result;
    const platform = Platform.of(b, t);
    const bundle_rev = b.option(u32, "bundle-rev", "Revision number in the bundle's name (default: 0)") orelse 0;
    const zstd = b.lazyDependency("zstd", .{}) orelse return;

    const packages = linkOrder(b, built);
    var archives: std.ArrayList(*Compile) = .empty;
    var link: std.ArrayList(Link) = .empty;
    for (ffmpegOrder(b, ffmpeg)) |lib| {
        archives.append(b.allocator, lib) catch @panic("OOM");
        link.append(b.allocator, .{ .name = lib.name, .kind = "static" }) catch @panic("OOM");
    }
    var needs_cxx = false;
    for (packages) |node| {
        archives.append(b.allocator, node.lib) catch @panic("OOM");
        link.append(b.allocator, .{ .name = node.lib.name, .kind = "static" }) catch @panic("OOM");
        if (linksLibcpp(node.lib)) needs_cxx = true;
    }
    if (needs_cxx) for (cxxRuntime(c)) |lib| {
        archives.append(b.allocator, lib) catch @panic("OOM");
        link.append(b.allocator, .{ .name = lib.name, .kind = "static" }) catch @panic("OOM");
    };
    for (systemLibs(c, built)) |name| link.append(b.allocator, .{ .name = name, .kind = "dylib" }) catch @panic("OOM");

    var sources: std.ArrayList(Meta.Source) = .empty;
    sources.appendSlice(b.allocator, ff.sources(version)) catch @panic("OOM");
    for (built) |lib| {
        if (bundledArchives(lib) == 0 and lib.output.archives.len > 0) continue;
        sources.appendSlice(b.allocator, lib.sources) catch @panic("OOM");
    }

    const spec: Spec = .{
        .variant = if (c.gpl) "gpl" else "lgpl",
        .ffmpeg_version = version.data().version,
        .bundle_rev = bundle_rev,
        .target = platform.triple,
        .glibc_floor = platform.glibc_floor,
        .suffix = platform.suffix,
        .zig = builtin.zig_version_string,
        .link = link.items,
        .sources = sourceList(b, sources.items),
    };
    const spec_json = std.json.Stringify.valueAlloc(b.allocator, spec, .{ .whitespace = .indent_2 }) catch @panic("OOM");
    const spec_file = b.addWriteFiles().add("spec.json", spec_json);

    const pack = b.addExecutable(.{
        .name = "bundle_pack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/bundle_pack.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    pack.root_module.linkLibrary(zstdLibrary(b, zstd));

    const run = b.addRunArtifact(pack);
    run.addFileArg(spec_file);
    const out = run.addOutputDirectoryArg("bundle");
    for (archives.items) |artifact| {
        run.addArg("--lib");
        run.addPrefixedArtifactArg(b.fmt("{s}=", .{platform.archiveFile(b, artifact.name)}), artifact);
    }
    for (programs) |exe| {
        run.addArg("--bin");
        run.addPrefixedArtifactArg(b.fmt("{s}{s}=", .{ exe.name, t.exeFileExt() }), exe);
    }
    for (ffmpeg) |artifact| {
        run.addArg("--include");
        run.addDirectoryArg(artifact.getEmittedIncludeTree());
    }
    for (sources.items) |s| {
        for (s.licenses) |file| {
            run.addArg("--license");
            run.addPrefixedFileArg(b.fmt("{s}=", .{s.name}), c.upstream(s.zon).path(file));
        }
    }
    if (needs_cxx) for ([_][]const u8{ "libcxx", "libcxxabi" }) |dir| {
        run.addArg("--license");
        run.addPrefixedFileArg(b.fmt("{s}=", .{dir}), std.Build.LazyPath.zig_lib.path(b, b.fmt("{s}/LICENSE.TXT", .{dir})));
    };

    const install = b.addInstallDirectory(.{ .source_dir = out, .install_dir = .prefix, .install_subdir = "bundle" });
    b.step("bundle", "Pack every archive, FFmpeg's headers and MANIFEST.json into <prefix>/bundle").dependOn(&install.step);

    const check = b.addExecutable(.{
        .name = "bundle_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/bundle_check.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
    const run_check = b.addRunArtifact(check);
    run_check.addDirectoryArg(out);
    _ = run_check.addOutputDirectoryArg("check");
    run_check.addArgs(&.{ b.graph.zig_exe, platform.zig_target });
    run_check.addFileArg(b.path("build/bundle_check.c"));
    const host = b.graph.host.result;
    run_check.addArg(if (host.cpu.arch == t.cpu.arch and host.os.tag == .linux and t.os.tag == .linux) "run" else "link");
    run_check.addArg(if (t.abi == .msvc) "msvc" else "gnu");
    if (c.libc_file) |file| run_check.addFileArg(file);
    b.step("bundle-check", "Link and run a C program against the bundle, in exactly MANIFEST.json's order").dependOn(&run_check.step);
}

/// How a bundle for the target is named and linked.
const Platform = struct {
    /// The Rust target triple a consumer builds for.
    triple: []const u8,
    /// The glibc version the archives need, `none` off Linux.
    glibc_floor: []const u8,
    suffix: []const u8,
    /// The `-target` bundle-check links with.
    zig_target: []const u8,
    msvc: bool,

    fn of(b: *std.Build, t: std.Target) Platform {
        const arch = @tagName(t.cpu.arch);
        switch (t.os.tag) {
            .linux => {
                if (!t.abi.isGnu()) std.debug.panic("bundles are defined for linux-gnu, not linux-{t}", .{t.abi});
                const glibc = t.os.versionRange().gnuLibCVersion().?;
                const floor = if (glibc.patch == 0) b.fmt("{d}.{d}", .{ glibc.major, glibc.minor }) else b.fmt("{d}.{d}.{d}", .{ glibc.major, glibc.minor, glibc.patch });
                return .{ .triple = b.fmt("{s}-unknown-linux-gnu", .{arch}), .glibc_floor = floor, .suffix = b.fmt("glibc{s}", .{floor}), .zig_target = b.fmt("{s}-linux-gnu.{s}", .{ arch, floor }), .msvc = false };
            },
            .windows => {
                const abi: []const u8 = switch (t.abi) {
                    .gnu => "gnu",
                    .msvc => "msvc",
                    else => std.debug.panic("bundles are defined for windows-gnu and windows-msvc, not windows-{t}", .{t.abi}),
                };
                const triple = b.fmt("{s}-pc-windows-{s}", .{ arch, abi });
                return .{ .triple = triple, .glibc_floor = "none", .suffix = triple, .zig_target = b.fmt("{s}-windows-{s}", .{ arch, abi }), .msvc = t.abi == .msvc };
            },
            .macos => {
                const triple = b.fmt("{s}-apple-darwin", .{arch});
                return .{ .triple = triple, .glibc_floor = "none", .suffix = triple, .zig_target = b.fmt("{s}-macos", .{arch}), .msvc = false };
            },
            else => std.debug.panic("bundles are not defined for {t}", .{t.os.tag}),
        }
    }

    /// The archive's file name in the bundle's `lib/`, as the target's linker looks it up.
    fn archiveFile(p: Platform, b: *std.Build, name: []const u8) []const u8 {
        return if (p.msvc) b.fmt("{s}.lib", .{name}) else b.fmt("lib{s}.a", .{name});
    }
};

fn bundledArchives(lib: Meta.Built) usize {
    var n: usize = 0;
    for (lib.output.archives) |a| n += @intFromBool(a.bundled);
    return n;
}

/// FFmpeg's libraries in `ff.link_order`; a library missing from it is a configure error.
fn ffmpegOrder(b: *std.Build, libs: []const *Compile) []const *Compile {
    var out: std.ArrayList(*Compile) = .empty;
    for (ff.link_order) |name| {
        for (libs) |lib| if (std.mem.eql(u8, lib.name, name)) out.append(b.allocator, lib) catch @panic("OOM");
    }
    if (out.items.len != libs.len) std.process.fatal("an FFmpeg library is missing from ffmpeg.zig's link_order", .{});
    return out.items;
}

/// Whether `lib` or an archive it links compiles C++ against libc++.
fn linksLibcpp(lib: *Compile) bool {
    for (lib.getCompileDependencies(true)) |dep| {
        for (dep.root_module.getGraph().modules) |mod| if (mod.link_libcpp orelse false) return true;
    }
    return false;
}

/// Whether package `from` needs package `to`, directly or through other packages.
fn needsTransitively(built: []const Meta.Built, from: usize, to: usize) bool {
    for (built[from].meta.needs) |name| {
        const need = for (built, 0..) |lib, i| {
            if (std.mem.eql(u8, lib.meta.name, name)) break i;
        } else continue;
        if (need == to or needsTransitively(built, need, to)) return true;
    }
    return false;
}

fn indexOfArchive(nodes: []const Node, package: usize, name: []const u8) ?usize {
    for (nodes, 0..) |node, i| {
        if (node.package == package and std.mem.eql(u8, node.lib.name, name)) return i;
    }
    return null;
}

/// Every bundled archive of `built` in link order: an archive precedes those its `links` name and
/// every archive of a package its package needs, and otherwise registry order holds. A cycle is a
/// configure error.
fn linkOrder(b: *std.Build, built: []const Meta.Built) []const Node {
    var all: std.ArrayList(Node) = .empty;
    for (built, 0..) |lib, package| {
        for (lib.output.archives) |a| {
            if (a.bundled) all.append(b.allocator, .{ .lib = a.lib, .package = package, .links = a.links }) catch @panic("OOM");
        }
    }
    const nodes = all.items;
    const n = nodes.len;
    const before = b.allocator.alloc(bool, n * n) catch @panic("OOM");
    @memset(before, false);
    for (nodes, 0..) |from, i| {
        for (from.links) |name| {
            const j = indexOfArchive(nodes, from.package, name) orelse std.debug.panic(
                "{s}'s lib{s}.a links {s}, which that package does not bundle",
                .{ built[from.package].meta.name, from.lib.name, name },
            );
            before[i * n + j] = true;
        }
        for (nodes, 0..) |to, j| {
            if (from.package != to.package and needsTransitively(built, from.package, to.package)) before[i * n + j] = true;
        }
    }

    const placed = b.allocator.alloc(bool, n) catch @panic("OOM");
    @memset(placed, false);
    var out: std.ArrayList(Node) = .empty;
    while (out.items.len < n) {
        const next = for (0..n) |k| {
            if (placed[k]) continue;
            const ready = for (0..n) |i| {
                if (before[i * n + k] and !placed[i]) break false;
            } else true;
            if (ready) break k;
        } else {
            var names: std.ArrayList(u8) = .empty;
            for (nodes, placed) |node, done| if (!done) names.print(b.allocator, " lib{s}.a", .{node.lib.name}) catch @panic("OOM");
            std.process.fatal("no link order exists for:{s}", .{names.items});
        };
        placed[next] = true;
        out.append(b.allocator, nodes[next]) catch @panic("OOM");
    }
    return out.items;
}

/// FFmpeg's own system libraries, then the ones the bundled packages ask for, once each.
fn systemLibs(c: Ctx, built: []const Meta.Built) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    out.appendSlice(c.b.allocator, config.systemLinkLibraries(c.target.result)) catch @panic("OOM");
    for (built) |lib| {
        if (bundledArchives(lib) == 0) continue;
        for (lib.meta.system_libs.forTarget(c)) |name| {
            if (!inList(out.items, name)) out.append(c.b.allocator, name) catch @panic("OOM");
        }
    }
    return out.items;
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn sourceList(b: *std.Build, sources: []const Meta.Source) []const SourceEntry {
    const out = b.allocator.alloc(SourceEntry, sources.len) catch @panic("OOM");
    for (out, sources) |*entry, s| entry.* = .{ .name = s.name, .version = s.version, .sha256 = s.hash, .url = s.url };
    return out;
}

fn zstdLibrary(b: *std.Build, zstd: *std.Build.Dependency) *Compile {
    const mod = b.createModule(.{ .target = b.graph.host, .optimize = .ReleaseFast, .link_libc = true });
    mod.addIncludePath(zstd.path("lib"));
    mod.addCSourceFiles(.{
        .root = zstd.path("lib"),
        .files = &.{
            "common/debug.c",                     "common/entropy_common.c",            "common/error_private.c",
            "common/fse_decompress.c",            "common/pool.c",                      "common/threading.c",
            "common/xxhash.c",                    "common/zstd_common.c",               "compress/fse_compress.c",
            "compress/hist.c",                    "compress/huf_compress.c",            "compress/zstd_compress.c",
            "compress/zstd_compress_literals.c",  "compress/zstd_compress_sequences.c", "compress/zstd_compress_superblock.c",
            "compress/zstd_double_fast.c",        "compress/zstd_fast.c",               "compress/zstd_lazy.c",
            "compress/zstd_ldm.c",                "compress/zstd_opt.c",                "compress/zstd_preSplit.c",
            "decompress/huf_decompress.c",        "decompress/zstd_ddict.c",            "decompress/zstd_decompress.c",
            "decompress/zstd_decompress_block.c",
        },
        .flags = &.{ "-DZSTD_DISABLE_ASM", "-DXXH_NAMESPACE=ZSTD_" },
    });
    return b.addLibrary(.{ .name = "zstd", .linkage = .static, .root_module = mod });
}

const cxxabi_files = [_][]const u8{
    "src/cxa_aux_runtime.cpp",       "src/cxa_default_handlers.cpp", "src/cxa_demangle.cpp",
    "src/cxa_exception_storage.cpp", "src/cxa_guard.cpp",            "src/cxa_handlers.cpp",
    "src/cxa_vector.cpp",            "src/cxa_virtual.cpp",          "src/stdlib_exception.cpp",
    "src/stdlib_stdexcept.cpp",      "src/stdlib_typeinfo.cpp",      "src/stdlib_new_delete.cpp",
    "src/abort_message.cpp",         "src/fallback_malloc.cpp",      "src/private_typeinfo.cpp",
    "src/cxa_exception.cpp",         "src/cxa_personality.cpp",      "src/cxa_thread_atexit.cpp",
};

const cxx_files = [_][]const u8{
    "src/algorithm.cpp",                     "src/any.cpp",                           "src/bind.cpp",
    "src/call_once.cpp",                     "src/charconv.cpp",                      "src/chrono.cpp",
    "src/error_category.cpp",                "src/exception.cpp",                     "src/expected.cpp",
    "src/filesystem/directory_entry.cpp",    "src/filesystem/directory_iterator.cpp", "src/filesystem/filesystem_clock.cpp",
    "src/filesystem/filesystem_error.cpp",   "src/filesystem/operations.cpp",         "src/filesystem/path.cpp",
    "src/fstream.cpp",                       "src/functional.cpp",                    "src/hash.cpp",
    "src/ios.cpp",                           "src/ios.instantiations.cpp",            "src/iostream.cpp",
    "src/locale.cpp",                        "src/memory.cpp",                        "src/memory_resource.cpp",
    "src/new.cpp",                           "src/new_handler.cpp",                   "src/new_helpers.cpp",
    "src/optional.cpp",                      "src/ostream.cpp",                       "src/print.cpp",
    "src/random.cpp",                        "src/random_shuffle.cpp",                "src/regex.cpp",
    "src/ryu/d2fixed.cpp",                   "src/ryu/d2s.cpp",                       "src/ryu/f2s.cpp",
    "src/stdexcept.cpp",                     "src/string.cpp",                        "src/strstream.cpp",
    "src/system_error.cpp",                  "src/typeinfo.cpp",                      "src/valarray.cpp",
    "src/variant.cpp",                       "src/vector.cpp",                        "src/verbose_abort.cpp",
    "src/atomic.cpp",                        "src/barrier.cpp",                       "src/condition_variable.cpp",
    "src/condition_variable_destructor.cpp", "src/future.cpp",                        "src/mutex.cpp",
    "src/mutex_destructor.cpp",              "src/shared_mutex.cpp",                  "src/thread.cpp",
};

const cxx_win32_files = [_][]const u8{ "src/support/win32/locale_win32.cpp", "src/support/win32/support.cpp", "src/support/win32/thread_win32.cpp" };

/// libc++ and libc++abi compiled from the sources and with the flags zig itself uses when a
/// program links `-lc++`, so objects built against zig's libc++ headers resolve against them.
fn cxxRuntime(c: Ctx) [2]*Compile {
    const b = c.b;
    const t = c.target.result;
    const lib = std.Build.LazyPath.zig_lib;
    const small = c.optimize == .small;
    const abi_dir = lib.path(b, "libcxxabi");
    const cxx_dir = lib.path(b, "libcxx");

    var common: std.ArrayList([]const u8) = .empty;
    common.appendSlice(b.allocator, &.{
        "-D_LIBCPP_ABI_VERSION=1",
        "-D_LIBCPP_ABI_NAMESPACE=__1",
        "-D_LIBCPP_HAS_THREADS=1",
        "-D_LIBCPP_HAS_MONOTONIC_CLOCK",
        "-D_LIBCPP_HAS_TERMINAL",
        b.fmt("-D_LIBCPP_HAS_MUSL_LIBC={d}", .{@intFromBool(t.abi.isMusl())}),
        "-D_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS",
        "-D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS",
        "-D_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS=0",
        "-D_LIBCPP_HAS_FILESYSTEM=1",
        "-D_LIBCPP_HAS_RANDOM_DEVICE",
        "-D_LIBCPP_HAS_LOCALIZATION",
        "-D_LIBCPP_HAS_UNICODE",
        "-D_LIBCPP_HAS_WIDE_CHARACTERS",
        "-D_LIBCPP_HAS_NO_STD_MODULES",
        "-D_LIBCPP_PSTL_BACKEND_SERIAL",
        "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_NONE",
        "-D_LIBCPP_ASSERTION_SEMANTIC_DEFAULT=_LIBCPP_ASSERTION_SEMANTIC_IGNORE",
        "-w",
        "-DNDEBUG",
        "-D_LIBCPP_BUILDING_LIBRARY",
        "-fvisibility=hidden",
        "-fvisibility-inlines-hidden",
        "-nostdinc++",
        "-std=c++23",
    }) catch @panic("OOM");
    if (t.os.tag == .linux) common.append(b.allocator, "-D_LIBCPP_HAS_TIME_ZONE_DATABASE") catch @panic("OOM");
    const glibc: ?std.SemanticVersion = if (t.isGnuLibC()) t.os.versionRange().gnuLibCVersion().? else null;
    if (glibc) |v| if (v.order(.{ .major = 2, .minor = 16, .patch = 0 }) == .lt) {
        common.append(b.allocator, "-D_LIBCPP_HAS_LIBRARY_ALIGNED_ALLOCATION=0") catch @panic("OOM");
    };

    var cxx_flags: std.ArrayList([]const u8) = .empty;
    cxx_flags.appendSlice(b.allocator, common.items) catch @panic("OOM");
    cxx_flags.appendSlice(b.allocator, &.{ "-DLIBC_NAMESPACE=__llvm_libc_common_utils", "-DLIBCXX_BUILDING_LIBCXXABI", "-D_LIBCPP_HAS_NO_PRAGMA_SYSTEM_HEADER", "-faligned-allocation" }) catch @panic("OOM");

    var abi_flags: std.ArrayList([]const u8) = .empty;
    abi_flags.appendSlice(b.allocator, common.items) catch @panic("OOM");
    abi_flags.appendSlice(b.allocator, &.{ "-D_LIBCXXABI_BUILDING_LIBRARY", "-fstrict-aliasing" }) catch @panic("OOM");
    if (t.abi.isGnu() and (glibc == null or glibc.?.order(.{ .major = 2, .minor = 18, .patch = 0 }) != .lt)) {
        abi_flags.append(b.allocator, "-DHAVE___CXA_THREAD_ATEXIT_IMPL") catch @panic("OOM");
    }

    const cxx_mod = runtimeModule(c, small, .none);
    cxx_mod.addIncludePath(cxx_dir.path(b, "include"));
    cxx_mod.addIncludePath(abi_dir.path(b, "include"));
    cxx_mod.addIncludePath(cxx_dir.path(b, "src"));
    cxx_mod.addIncludePath(cxx_dir.path(b, "libc"));
    cxx_mod.addCSourceFiles(.{ .root = cxx_dir, .files = &cxx_files, .flags = cxx_flags.items, .language = .cpp });
    if (t.os.tag == .windows) cxx_mod.addCSourceFiles(.{ .root = cxx_dir, .files = &cxx_win32_files, .flags = cxx_flags.items, .language = .cpp });

    const abi_mod = runtimeModule(c, small, if (t.cpu.arch == .x86 and t.os.tag == .windows) .none else .async);
    abi_mod.addIncludePath(abi_dir.path(b, "include"));
    abi_mod.addIncludePath(cxx_dir.path(b, "include"));
    abi_mod.addIncludePath(cxx_dir.path(b, "src"));
    abi_mod.addCSourceFiles(.{ .root = abi_dir, .files = &cxxabi_files, .flags = abi_flags.items, .language = .cpp });

    const cxx_lib = c.staticLibrary("c++", cxx_mod);
    const abi_lib = c.staticLibrary("c++abi", abi_mod);
    for ([_]*Compile{ cxx_lib, abi_lib }) |l| {
        l.link_function_sections = true;
        l.link_data_sections = true;
    }
    return .{ cxx_lib, abi_lib };
}

fn runtimeModule(c: Ctx, small: bool, unwind: std.builtin.UnwindTables) *std.Build.Module {
    return c.b.createModule(.{
        .target = c.target,
        .optimize = if (small) .ReleaseSmall else .ReleaseFast,
        .link_libc = true,
        .pic = true,
        .strip = c.strip,
        .sanitize_c = .off,
        .stack_protector = false,
        .unwind_tables = unwind,
    });
}
