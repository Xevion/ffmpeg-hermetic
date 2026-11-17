//! The `bundle` step: libc++ and libc++abi built from zig's bundled sources, then every archive,
//! FFmpeg's headers and a MANIFEST.json packed into an ffoxide bundle directory and `.tar.zst`.
const std = @import("std");
const builtin = @import("builtin");
const Ctx = @import("Ctx.zig");
const Meta = @import("Meta.zig");
const ff = @import("ffmpeg.zig");

const Compile = std.Build.Step.Compile;

/// The pins that are always in a bundle, before those of the libraries that went into it.
const fixed_sources = Meta.sources(ff.meta) ++ Meta.sources(ff.nv_codec_headers);

/// Archive names in link order: each appears before the libraries it needs. A bundled archive
/// missing from this list is left out of the bundle with a warning.
const link_order = [_][]const u8{
    "avdevice", "avfilter", "avformat",  "avcodec",    "vpx",       "dav1d",    "aom",
    "mp3lame",  "opus",     "SvtAv1Enc", "x264",       "x265",      "openh264", "kvazaar",
    "ass",      "harfbuzz", "freetype",  "fribidi",    "openjp2",   "webpmux",  "webpdemux",
    "webp",     "sharpyuv", "theoraenc", "theoradec",  "vorbisenc", "vorbis",   "ogg",
    "zimg",     "bz2",      "lzma",      "swresample", "soxr",      "swscale",  "avutil",
    "z",        "drm",      "va",        "c++",        "c++abi",
};

const Link = struct { name: []const u8, kind: []const u8 };
const SourceEntry = struct { name: []const u8, version: []const u8, sha256: []const u8, url: []const u8 };

const Spec = struct {
    variant: []const u8,
    ffmpeg_version: []const u8,
    bundle_rev: u32,
    target: []const u8,
    glibc_floor: []const u8,
    zig: []const u8,
    link: []const Link,
    sources: []const SourceEntry,
};

/// Adds the `bundle` step. `codecs` are the external libraries that were built, `ffmpeg` the seven
/// FFmpeg libraries whose installed headers become the bundle's include directory.
pub fn add(c: Ctx, codecs: []const Meta.Built, ffmpeg: []const *Compile) void {
    const b = c.b;
    const t = c.target.result;
    if (t.os.tag != .linux or !t.abi.isGnu()) {
        std.debug.panic("bundles are only defined for linux-gnu targets so far, not {s}-{s}", .{ @tagName(t.os.tag), @tagName(t.abi) });
    }
    const glibc = t.os.versionRange().gnuLibCVersion().?;
    const bundle_rev = b.option(u32, "bundle-rev", "Revision number in the bundle's name (default: 0)") orelse 0;
    const zstd = b.lazyDependency("zstd", .{}) orelse return;

    const cxx = cxxRuntime(c);
    var archives: std.ArrayList(*Compile) = .empty;
    var sources: std.ArrayList(Meta.Source) = .empty;
    sources.appendSlice(b.allocator, fixed_sources) catch @panic("OOM");
    for (codecs) |codec| {
        var kept = false;
        for (codec.output.archives) |a| {
            if (!a.bundled) continue;
            if (inList(&link_order, a.lib.name)) {
                archives.append(b.allocator, a.lib) catch @panic("OOM");
                kept = true;
            } else {
                std.log.warn("lib{s}.a is not in bundle.zig's link_order and is left out of the bundle", .{a.lib.name});
            }
        }
        if (kept) sources.appendSlice(b.allocator, codec.sources) catch @panic("OOM");
    }
    archives.appendSlice(b.allocator, ffmpeg) catch @panic("OOM");
    archives.appendSlice(b.allocator, &cxx) catch @panic("OOM");

    const spec: Spec = .{
        .variant = if (c.gpl) "gpl" else "lgpl",
        .ffmpeg_version = fixed_sources[0].version,
        .bundle_rev = bundle_rev,
        .target = b.fmt("{s}-unknown-linux-gnu", .{@tagName(t.cpu.arch)}),
        .glibc_floor = if (glibc.patch == 0) b.fmt("{d}.{d}", .{ glibc.major, glibc.minor }) else b.fmt("{d}.{d}.{d}", .{ glibc.major, glibc.minor, glibc.patch }),
        .zig = builtin.zig_version_string,
        .link = linkList(c, archives.items),
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
        run.addArtifactArg(artifact);
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
    for ([_][]const u8{ "libcxx", "libcxxabi" }) |dir| {
        run.addArg("--license");
        run.addPrefixedFileArg(b.fmt("{s}=", .{dir}), std.Build.LazyPath.zig_lib.path(b, b.fmt("{s}/LICENSE.TXT", .{dir})));
    }

    const install = b.addInstallDirectory(.{ .source_dir = out, .install_dir = .prefix, .install_subdir = "bundle" });
    b.step("bundle", "Pack every archive, FFmpeg's headers and MANIFEST.json into <prefix>/bundle").dependOn(&install.step);
}

fn inList(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn hasArchive(archives: []const *Compile, name: []const u8) bool {
    for (archives) |a| if (std.mem.eql(u8, a.name, name)) return true;
    return false;
}

fn linkList(c: Ctx, archives: []const *Compile) []const Link {
    const b = c.b;
    var out: std.ArrayList(Link) = .empty;
    for (link_order) |name| {
        if (hasArchive(archives, name)) out.append(b.allocator, .{ .name = name, .kind = "static" }) catch @panic("OOM");
    }
    for ([_][]const u8{ "pthread", "rt", "m", "dl" }) |name| {
        out.append(b.allocator, .{ .name = name, .kind = "dylib" }) catch @panic("OOM");
    }
    return out.items;
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
        "-D_LIBCPP_HAS_TIME_ZONE_DATABASE",
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
    const glibc = t.os.versionRange().gnuLibCVersion().?;
    if (glibc.order(.{ .major = 2, .minor = 16, .patch = 0 }) == .lt) {
        common.append(b.allocator, "-D_LIBCPP_HAS_LIBRARY_ALIGNED_ALLOCATION=0") catch @panic("OOM");
    }

    var cxx_flags: std.ArrayList([]const u8) = .empty;
    cxx_flags.appendSlice(b.allocator, common.items) catch @panic("OOM");
    cxx_flags.appendSlice(b.allocator, &.{ "-DLIBC_NAMESPACE=__llvm_libc_common_utils", "-DLIBCXX_BUILDING_LIBCXXABI", "-D_LIBCPP_HAS_NO_PRAGMA_SYSTEM_HEADER", "-faligned-allocation" }) catch @panic("OOM");

    var abi_flags: std.ArrayList([]const u8) = .empty;
    abi_flags.appendSlice(b.allocator, common.items) catch @panic("OOM");
    abi_flags.appendSlice(b.allocator, &.{ "-D_LIBCXXABI_BUILDING_LIBRARY", "-fstrict-aliasing" }) catch @panic("OOM");
    if (glibc.order(.{ .major = 2, .minor = 18, .patch = 0 }) != .lt) {
        abi_flags.append(b.allocator, "-DHAVE___CXA_THREAD_ATEXIT_IMPL") catch @panic("OOM");
    }

    const cxx_mod = runtimeModule(c, small, .none);
    cxx_mod.addIncludePath(cxx_dir.path(b, "include"));
    cxx_mod.addIncludePath(abi_dir.path(b, "include"));
    cxx_mod.addIncludePath(cxx_dir.path(b, "src"));
    cxx_mod.addIncludePath(cxx_dir.path(b, "libc"));
    cxx_mod.addCSourceFiles(.{ .root = cxx_dir, .files = &cxx_files, .flags = cxx_flags.items, .language = .cpp });

    const abi_mod = runtimeModule(c, small, .async);
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
