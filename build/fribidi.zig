const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "fribidi",
    .version = "1.0.18",
    .licenses = &.{"COPYING"},
    .ffmpeg = &.{"libfribidi"},
    .ffmpeg_windows_defines = &.{"FRIBIDI_LIB_STATIC"},
    .ffmpeg_include_subdirs = &.{"fribidi"},
};

/// GNU FriBidi, using the unicode tables the release tarball ships in `lib/`.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const ver = Meta.versionParts(meta.version);
    const b = c.b;
    const src = c.upstream("fribidi");
    const windows = c.isWindows();

    const config = b.addConfigHeader(.{
        .style = .{ .autoconf_at = src.path("lib/fribidi-config.h.in") },
        .include_path = "fribidi-config.h",
    }, .{
        .configure_input = "fribidi-config.h",
        .PACKAGE = "fribidi",
        .PACKAGE_NAME = "GNU FriBidi",
        .PACKAGE_BUGREPORT = "https://github.com/fribidi/fribidi/issues/new",
        .FRIBIDI_VERSION = meta.version,
        .FRIBIDI_MAJOR_VERSION = ver[0],
        .FRIBIDI_MINOR_VERSION = ver[1],
        .FRIBIDI_MICRO_VERSION = ver[2],
        .FRIBIDI_INTERFACE_VERSION = 4,
        .SIZEOF_INT = 4,
        .FRIBIDI_MSVC_BUILD_PLACEHOLDER = if (c.isMsvc()) "#define FRIBIDI_BUILT_WITH_MSVC" else "#undef FRIBIDI_BUILT_WITH_MSVC",
    });

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{
        "-DHAVE_STDLIB_H=1", "-DHAVE_STRING_H=1", "-DHAVE_MEMORY_H=1", "-DHAVE_STRINGIZE=1",
        "-DHAVE_MEMMOVE",    "-DHAVE_MEMSET",     "-DHAVE_STRDUP",     "-DFRIBIDI_BUILD",
    }) catch @panic("OOM");
    if (!windows) flags.appendSlice(b.allocator, &.{ "-DHAVE_STRINGS_H", "-DSTDC_HEADERS=1" }) catch @panic("OOM");
    if (windows) flags.append(b.allocator, "-DFRIBIDI_LIB_STATIC") catch @panic("OOM");

    const mod = c.module(.{});
    mod.addConfigHeader(config);
    mod.addIncludePath(src.path("lib"));
    mod.addCSourceFiles(.{ .root = src.path("lib"), .files = &sources, .flags = flags.items });

    const lib = c.staticLibrary("fribidi", mod);
    for (headers) |h| lib.installHeader(src.path(b.fmt("lib/{s}", .{h})), b.fmt("fribidi/{s}", .{h}));
    lib.installHeader(config.getOutputFile(), "fribidi/fribidi-config.h");
    return c.single(lib);
}

const sources = [_][]const u8{
    "fribidi.c",                     "fribidi-arabic.c",           "fribidi-bidi.c",
    "fribidi-bidi-types.c",          "fribidi-char-sets.c",        "fribidi-char-sets-cap-rtl.c",
    "fribidi-char-sets-cp1255.c",    "fribidi-char-sets-cp1256.c", "fribidi-char-sets-iso8859-6.c",
    "fribidi-char-sets-iso8859-8.c", "fribidi-char-sets-utf8.c",   "fribidi-deprecated.c",
    "fribidi-joining.c",             "fribidi-joining-types.c",    "fribidi-mirroring.c",
    "fribidi-brackets.c",            "fribidi-run.c",              "fribidi-shape.c",
};

const headers = [_][]const u8{
    "fribidi-arabic.h",         "fribidi-begindecls.h",         "fribidi-bidi.h",
    "fribidi-bidi-types.h",     "fribidi-bidi-types-list.h",    "fribidi-char-sets.h",
    "fribidi-char-sets-list.h", "fribidi-common.h",             "fribidi-deprecated.h",
    "fribidi-enddecls.h",       "fribidi-flags.h",              "fribidi-joining.h",
    "fribidi-joining-types.h",  "fribidi-joining-types-list.h", "fribidi-mirroring.h",
    "fribidi-brackets.h",       "fribidi-shape.h",              "fribidi-types.h",
    "fribidi-unicode.h",        "fribidi-unicode-version.h",    "fribidi.h",
};
