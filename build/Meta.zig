//! What the build knows about one library, declared next to its `build` as `pub const meta` and
//! read by the registry, FFmpeg's configuration and the bundle.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const pins = @import("../build.zig.zon");

const Meta = @This();

/// Registry name: the `-D<name>` option and the key of `Ctx.dep`. A bundle's MANIFEST spells it with dashes.
name: []const u8,
/// Key in build.zig.zon when it differs from `name`.
zon: []const u8 = "",
/// Version of the pinned source, and the one place a port reads it from. It must appear in the
/// pin's URL, so bumping the pin without it fails to compile; a git pin names its commit prefix.
version: []const u8,
/// License files in the source tree, copied into a bundle.
licenses: []const []const u8 = &.{},
/// Further pinned sources compiled into this library.
extra_sources: []const Extra = &.{},
/// Libraries built first, whose installed headers this one compiles against and whose archives it
/// links. When one is disabled or unavailable this library is skipped too.
needs: []const []const u8 = &.{},
/// configure names FFmpeg enables when this library is built (`--enable-<name>`).
ffmpeg: []const []const u8 = &.{},
/// Subdirectories of its include tree that the library's pkg-config Cflags put on the include
/// path, because FFmpeg includes those headers without the directory.
ffmpeg_include_subdirs: []const []const u8 = &.{},
/// Names configure sets only while probing this library, as the pinned version answers
/// (`libx264_hdr10`, vaapi's `VA*` types). They are on when the library is built, unset otherwise.
ffmpeg_probes: []const []const u8 = &.{},
/// Preprocessor defines FFmpeg's configure adds to every compile once it has probed this library.
ffmpeg_defines: []const []const u8 = &.{},
/// Preprocessor defines its pkg-config Cflags add for static use on Windows, which FFmpeg's
/// own sources need so the installed headers do not declare dllimport.
ffmpeg_windows_defines: []const []const u8 = &.{},
/// Libraries a consumer of its archives links besides the package's own.
system_libs: SystemLibs = .{},
license: License = .lgpl,
/// Whether the library builds for the target.
supports: *const fn (Ctx) bool = support.always,

pub const License = enum {
    /// Usable in every build.
    lgpl,
    /// Needs `-Dgpl`.
    gpl,
    /// FFmpeg accepts it in GPL builds only with `-Dversion3`.
    gpl_needs_version3,
};

pub const SystemLibs = struct {
    linux: []const []const u8 = &.{},
    windows: []const []const u8 = &.{},
    macos: []const []const u8 = &.{},

    pub fn forTarget(s: SystemLibs, c: Ctx) []const []const u8 {
        return switch (c.os()) {
            .linux => s.linux,
            .windows => s.windows,
            .macos => s.macos,
            else => &.{},
        };
    }
};

pub const Extra = struct {
    zon: []const u8,
    version: []const u8,
    licenses: []const []const u8 = &.{},
};

/// A pinned upstream tarball, as a bundle's MANIFEST records it.
pub const Source = struct {
    zon: []const u8,
    name: []const u8,
    version: []const u8,
    url: []const u8,
    hash: []const u8,
    licenses: []const []const u8,
};

/// A library that was built: its metadata, its pins and what it produced.
pub const Built = struct {
    meta: *const Meta,
    sources: []const Source,
    output: Ctx.Output,
};

/// Target predicates for `supports`.
pub const support = struct {
    pub fn always(_: Ctx) bool {
        return true;
    }

    pub fn linux(c: Ctx) bool {
        return c.os() == .linux;
    }

    pub fn linuxOrWindows(c: Ctx) bool {
        return c.os() == .linux or c.os() == .windows;
    }

    pub fn notMsvc(c: Ctx) bool {
        return !c.isMsvc();
    }

    pub fn x86_64OnMsvc(c: Ctx) bool {
        return !c.isMsvc() or c.arch() == .x86_64;
    }
};

pub fn zonName(comptime m: Meta) []const u8 {
    return if (m.zon.len == 0) m.name else m.zon;
}

/// `parts[0].parts[1].parts[2]` of `version`, missing or non-numeric parts being 0.
pub fn versionParts(version: []const u8) [3]u32 {
    var out: [3]u32 = @splat(0);
    var it = std.mem.splitScalar(u8, version, '.');
    for (&out) |*part| {
        const text = it.next() orelse break;
        part.* = std.fmt.parseInt(u32, text, 10) catch 0;
    }
    return out;
}

fn dashed(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len]u8 = undefined;
        for (name, &buf) |ch, *out| out.* = if (ch == '_') '-' else ch;
        const done = buf;
        return &done;
    }
}

fn source(comptime zon: []const u8, comptime version: []const u8, comptime licenses: []const []const u8) Source {
    const pin = @field(pins.dependencies, zon);
    comptime if (std.mem.indexOf(u8, pin.url, version) == null) {
        @compileError("build.zig.zon pins " ++ zon ++ " at a URL that does not contain " ++ version);
    };
    return .{ .zon = zon, .name = dashed(zon), .version = version, .url = pin.url, .hash = pin.hash, .licenses = licenses };
}

/// The pins of `m`: its own source first, then `extra_sources`. A version missing from a pin's URL is a compile error.
pub fn sources(comptime m: Meta) []const Source {
    comptime {
        var out: [1 + m.extra_sources.len]Source = undefined;
        out[0] = source(m.zonName(), m.version, m.licenses);
        out[0].name = dashed(m.name);
        for (m.extra_sources, out[1..]) |extra, *slot| slot.* = source(extra.zon, extra.version, extra.licenses);
        const done = out;
        return &done;
    }
}
