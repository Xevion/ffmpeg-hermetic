//! Intel oneVPL dispatcher as a static libvpl. It only loads the GPU runtime at run time.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "libvpl",
    .version = "2.17.0",
    .licenses = &.{"LICENSE"},
    .spdx = "MIT",
    .ffmpeg = &.{"libvpl"},
    .ffmpeg_probes = &.{ "libmfx", "struct_mfxConfigInterface", "MFX_CODEC_VP9" },
    .ffmpeg_defines = &.{"MFX_DEPRECATED_OFF"},
    .ffmpeg_include_subdirs = &.{"vpl"},
    .system_libs = .{ .linux = &.{ "pthread", "dl" }, .windows = &.{ "ole32", "gdi32", "uuid", "advapi32" } },
    // The dispatcher only knows Linux and Windows runtimes, as upstream.
    .supports = Meta.support.linuxOrWindows,
};

/// Fallback location of the runtime for the legacy loader; the oneVPL search also tries the
/// usual system library directories on its own.
const modules_dir = "/usr/lib/x86_64-linux-gnu";

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    const src = c.upstream("libvpl");
    const mod = c.module(.{ .cpp = true });

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(c.b.allocator, &.{ "-DMFX_DEPRECATED_OFF", "-DONEVPL_EXPERIMENTAL" }) catch @panic("OOM");
    if (!c.isWindows()) flags.append(c.b.allocator, "-DMFX_MODULES_DIR=\"" ++ modules_dir ++ "\"") catch @panic("OOM");

    const files = if (c.isWindows()) &(common ++ windows) else &(common ++ linux);
    c.addSources(mod, "vpl", .{
        .module = .{ .cpp = true },
        .setup = .{ .includes = &.{ src.path("libvpl"), src.path("api") } },
        .groups = &.{.{ .root = src.path("libvpl"), .files = files, .flags = flags.items }},
    });

    const lib = c.staticLibrary("vpl", mod);
    lib.installHeadersDirectory(src.path("api/vpl"), "vpl", .{});
    return c.single(lib);
}

const common = [_][]const u8{
    "src/mfx_dispatcher_vpl.cpp",
    "src/mfx_dispatcher_vpl_loader.cpp",
    "src/mfx_dispatcher_vpl_config.cpp",
    "src/mfx_dispatcher_vpl_lowlatency.cpp",
    "src/mfx_dispatcher_vpl_log.cpp",
    "src/mfx_dispatcher_vpl_msdk.cpp",
    "src/mfx_config_interface/mfx_config_interface.cpp",
    "src/mfx_config_interface/mfx_config_interface_string_api.cpp",
};

const linux = [_][]const u8{"src/linux/mfxloader.cpp"};

const windows = [_][]const u8{
    "src/windows/main.cpp",
    "src/windows/mfx_critical_section.cpp",
    "src/windows/mfx_dispatcher.cpp",
    "src/windows/mfx_dispatcher_log.cpp",
    "src/windows/mfx_driver_store_loader.cpp",
    "src/windows/mfx_dxva2_device.cpp",
    "src/windows/mfx_function_table.cpp",
    "src/windows/mfx_library_iterator.cpp",
    "src/windows/mfx_load_dll.cpp",
    "src/windows/mfx_win_reg_key.cpp",
};
