//! OpenSSL 3 as static libssl and libcrypto: the default provider only, no engines, legacy
//! provider, QUIC or apps. Source lists, defines, headers and perlasm output come from gen/openssl.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Group = @import("../gen/openssl/group.zig").Group;

/// Where libcrypto looks for `certs/` and `cert.pem` when SSL_CERT_FILE and SSL_CERT_DIR are
/// unset. Debian, Ubuntu, Alpine, Arch and SUSE keep the system CA store under it.
const openssl_dir = "/etc/ssl";

const Lists = struct { crypto: Group, ssl: Group, default: Group, common: Group };

fn lists(arch: std.Target.Cpu.Arch) Lists {
    return switch (arch) {
        .x86_64 => .{
            .crypto = @import("../gen/openssl/x86_64/sources.zig").crypto,
            .ssl = @import("../gen/openssl/x86_64/sources.zig").ssl,
            .default = @import("../gen/openssl/x86_64/sources.zig").default,
            .common = @import("../gen/openssl/x86_64/sources.zig").common,
        },
        .aarch64 => .{
            .crypto = @import("../gen/openssl/aarch64/sources.zig").crypto,
            .ssl = @import("../gen/openssl/aarch64/sources.zig").ssl,
            .default = @import("../gen/openssl/aarch64/sources.zig").default,
            .common = @import("../gen/openssl/aarch64/sources.zig").common,
        },
        else => std.debug.panic("no checked-in OpenSSL sources for {s}; run tools/gen_openssl.sh", .{@tagName(arch)}),
    };
}

/// libssl, which carries the installed headers, and the libcrypto it needs at link time.
pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const b = c.b;
    const src = c.upstream("openssl");
    const gen = b.path(b.fmt("gen/openssl/{s}", .{@tagName(c.arch())}));
    const l = lists(c.arch());

    const crypto = module(c, src, gen, l.crypto);
    // libcrypto.a also holds the default provider, which upstream builds as separate archives.
    for ([_]struct { []const u8, Group }{ .{ "default", l.default }, .{ "common", l.common } }) |part| {
        c.addSources(crypto, part[0], .{ .setup = setup(c, src, gen, part[1]), .groups = groups(c, src, gen, part[1]) });
    }
    const crypto_lib = c.staticLibrary("crypto", crypto);

    const ssl_lib = c.staticLibrary("ssl", module(c, src, gen, l.ssl));

    for ([_]std.Build.LazyPath{ gen.path(b, "include/openssl"), src.path("include/openssl") }) |dir| {
        ssl_lib.installHeadersDirectory(dir, "openssl", .{ .include_extensions = &.{".h"} });
    }
    return c.package(&.{
        .{ .lib = ssl_lib, .links = &.{"crypto"} },
        .{ .lib = crypto_lib },
    });
}

fn flagsFor(c: Ctx, g: Group) []const []const u8 {
    const a = c.b.allocator;
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(a, &.{
        "-DOPENSSL_USE_NODELETE",
        "-DL_ENDIAN",
        "-DOPENSSL_PIC",
        "-DOPENSSLDIR=\"" ++ openssl_dir ++ "\"",
        "-DENGINESDIR=\"/usr/lib/engines\"",
        "-DMODULESDIR=\"/usr/lib/ossl-modules\"",
        "-DOPENSSL_BUILDING_OPENSSL",
        "-DNDEBUG",
    }) catch @panic("OOM");
    for (g.defines) |d| flags.append(a, c.b.fmt("-D{s}", .{d})) catch @panic("OOM");
    return flags.items;
}

/// A group's include directories exist both in the OpenSSL tree and in gen, where the generated
/// headers live.
fn setup(c: Ctx, src: *std.Build.Dependency, gen: std.Build.LazyPath, g: Group) Ctx.Setup {
    const includes = c.b.allocator.alloc(std.Build.LazyPath, g.includes.len * 2) catch @panic("OOM");
    for (g.includes, 0..) |dir, i| {
        const dot = std.mem.eql(u8, dir, ".");
        includes[2 * i] = if (dot) gen else gen.path(c.b, dir);
        includes[2 * i + 1] = if (dot) src.path("") else src.path(dir);
    }
    return .{ .includes = includes };
}

fn groups(c: Ctx, src: *std.Build.Dependency, gen: std.Build.LazyPath, g: Group) []const Ctx.SourceGroup {
    const flags = flagsFor(c, g);
    return c.b.allocator.dupe(Ctx.SourceGroup, &.{
        .{ .root = src.path(""), .files = g.c, .flags = flags },
        .{ .root = gen, .files = g.gen_c, .flags = flags },
        .{ .root = gen, .files = g.asm_files, .flags = flags },
    }) catch @panic("OOM");
}

fn module(c: Ctx, src: *std.Build.Dependency, gen: std.Build.LazyPath, g: Group) *std.Build.Module {
    const m = c.module(.{});
    setup(c, src, gen, g).apply(m);
    Ctx.addGroups(m, groups(c, src, gen, g));
    return m;
}
