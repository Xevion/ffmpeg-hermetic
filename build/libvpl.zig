//! Intel oneVPL dispatcher as a static libvpl. It only loads the GPU runtime at run time.
const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");

/// Fallback location of the runtime for the legacy loader; the oneVPL search also tries the
/// usual system library directories on its own.
const modules_dir = "/usr/lib/x86_64-linux-gnu";

pub fn build(c: Ctx, _: Nasm) *std.Build.Step.Compile {
    const src = c.upstream("libvpl");
    const mod = c.module(.{ .cpp = true });

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(c.b.allocator, &.{ "-DMFX_DEPRECATED_OFF", "-DONEVPL_EXPERIMENTAL" }) catch @panic("OOM");
    if (!c.isWindows()) flags.append(c.b.allocator, "-DMFX_MODULES_DIR=\"" ++ modules_dir ++ "\"") catch @panic("OOM");

    const files = if (c.isWindows()) &(common ++ windows) else &(common ++ linux);
    const setup = struct {
        fn f(m: *std.Build.Module, s: *std.Build.Dependency) void {
            m.addIncludePath(s.path("libvpl"));
            m.addIncludePath(s.path("api"));
        }
    }.f;
    c.addObjectsTo(mod, "vpl", .{
        .module = .{ .cpp = true },
        .root = src.path("libvpl"),
        .groups = &.{.{ .files = files, .flags = flags.items }},
    }, setup, .{src});

    const lib = c.staticLibrary("vpl", mod);
    lib.installHeadersDirectory(src.path("api/vpl"), "vpl", .{});
    return lib;
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
