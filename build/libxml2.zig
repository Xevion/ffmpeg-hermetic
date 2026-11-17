const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "libxml2",
    .version = "2.15.4",
    .licenses = &.{"Copyright"},
    .ffmpeg = &.{"libxml2"},
    .ffmpeg_windows_defines = &.{"LIBXML_STATIC"},
    .ffmpeg_include_subdirs = &.{"libxml2"},
    .system_libs = .{ .linux = &.{ "m", "pthread", "dl" }, .windows = &.{"bcrypt"} },
};

/// libxml2 with upstream's default feature set, minus zlib, lzma and ICU, and iconv on Linux only.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const ver = Meta.versionParts(meta.version);
    const b = c.b;
    const src = c.upstream("libxml2");
    const t = c.target.result;
    const posix = !c.isWindows();
    const iconv = t.os.tag == .linux;
    const glibc_getentropy = if (t.os.versionRange().gnuLibCVersion()) |v| v.order(.{ .major = 2, .minor = 25, .patch = 0 }) != .lt else true;
    const getentropy = switch (t.os.tag) {
        .linux => !t.abi.isGnu() or glibc_getentropy,
        .macos, .freebsd, .openbsd => true,
        else => false,
    };

    const config = b.addConfigHeader(.{
        .style = .{ .cmake = src.path("config.h.cmake.in") },
        .include_path = "config.h",
    }, .{
        .HAVE_DECL_GETENTROPY = @as(i64, @intFromBool(getentropy)),
        .HAVE_DECL_GLOB = @as(i64, @intFromBool(posix)),
        .HAVE_DECL_MMAP = @as(i64, @intFromBool(posix)),
        .HAVE_FUNC_ATTRIBUTE_DESTRUCTOR = true,
        .HAVE_DLOPEN = posix,
        .HAVE_LIBHISTORY = false,
        .HAVE_LIBREADLINE = false,
        .HAVE_SHLLOAD = false,
        .HAVE_STDINT_H = true,
        .XML_SYSCONFDIR = "/etc",
        .XML_THREAD_LOCAL = false,
    });
    const version = b.addConfigHeader(.{
        .style = .{ .cmake = src.path("include/libxml/xmlversion.h.in") },
        .include_path = "libxml/xmlversion.h",
    }, .{
        .VERSION = meta.version,
        .LIBXML_VERSION_NUMBER = ver[0] * 10000 + ver[1] * 100 + ver[2],
        .LIBXML_VERSION_EXTRA = "",
        .WITH_THREADS = 1,
        .WITH_THREAD_ALLOC = 0,
        .WITH_OUTPUT = 1,
        .WITH_PUSH = 1,
        .WITH_READER = 1,
        .WITH_PATTERN = 1,
        .WITH_WRITER = 1,
        .WITH_SAX1 = 1,
        .WITH_HTTP = 0,
        .WITH_VALID = 1,
        .WITH_HTML = 1,
        .WITH_C14N = 1,
        .WITH_CATALOG = 1,
        .WITH_XPATH = 1,
        .WITH_XPTR = 1,
        .WITH_XINCLUDE = 1,
        .WITH_ICONV = @as(i64, @intFromBool(iconv)),
        .WITH_ICU = 0,
        .WITH_ISO8859X = 1,
        .WITH_DEBUG = 1,
        .WITH_REGEXPS = 1,
        .WITH_RELAXNG = 1,
        .WITH_SCHEMAS = 1,
        .WITH_SCHEMATRON = 0,
        .WITH_MODULES = 1,
        .WITH_ZLIB = 0,
        .MODULE_EXTENSION = if (c.isWindows()) ".dll" else if (t.os.tag.isDarwin()) ".dylib" else ".so",
    });

    var flags: std.ArrayList([]const u8) = .empty;
    flags.append(b.allocator, "-std=gnu11") catch @panic("OOM");
    if (c.isWindows()) flags.append(b.allocator, "-DLIBXML_STATIC") catch @panic("OOM");

    const mod = c.module(.{});
    mod.addConfigHeader(config);
    mod.addConfigHeader(version);
    mod.addIncludePath(src.path("include"));
    mod.addCSourceFiles(.{ .root = src.path(""), .files = &sources, .flags = flags.items });
    if (c.isWindows()) mod.linkSystemLibrary("bcrypt", .{});

    const lib = c.staticLibrary("xml2", mod);
    for (headers) |h| lib.installHeader(src.path(b.fmt("include/libxml/{s}", .{h})), b.fmt("libxml2/libxml/{s}", .{h}));
    lib.installHeader(version.getOutputFile(), "libxml2/libxml/xmlversion.h");
    return c.single(lib);
}

const sources = [_][]const u8{
    "buf.c",        "chvalid.c",         "dict.c",      "encoding.c",  "entities.c",        "error.c",
    "globals.c",    "hash.c",            "list.c",      "parser.c",    "parserInternals.c", "SAX2.c",
    "threads.c",    "tree.c",            "uri.c",       "valid.c",     "xmlIO.c",           "xmlmemory.c",
    "xmlstring.c",  "c14n.c",            "catalog.c",   "debugXML.c",  "HTMLparser.c",      "HTMLtree.c",
    "xmlmodule.c",  "xmlsave.c",         "pattern.c",   "xmlreader.c", "xmlregexp.c",       "relaxng.c",
    "xmlschemas.c", "xmlschemastypes.c", "xmlwriter.c", "xinclude.c",  "xpath.c",           "xlink.c",
    "xpointer.c",
};

const headers = [_][]const u8{
    "c14n.h",     "catalog.h",        "chvalid.h",          "debugXML.h",        "dict.h",       "encoding.h",
    "entities.h", "globals.h",        "hash.h",             "HTMLparser.h",      "HTMLtree.h",   "list.h",
    "nanoftp.h",  "nanohttp.h",       "parser.h",           "parserInternals.h", "pattern.h",    "relaxng.h",
    "SAX.h",      "SAX2.h",           "schemasInternals.h", "schematron.h",      "threads.h",    "tree.h",
    "uri.h",      "valid.h",          "xinclude.h",         "xlink.h",           "xmlIO.h",      "xmlautomata.h",
    "xmlerror.h", "xmlexports.h",     "xmlmemory.h",        "xmlmodule.h",       "xmlreader.h",  "xmlregexp.h",
    "xmlsave.h",  "xmlschemas.h",     "xmlschemastypes.h",  "xmlstring.h",       "xmlunicode.h", "xmlwriter.h",
    "xpath.h",    "xpathInternals.h", "xpointer.h",
};
