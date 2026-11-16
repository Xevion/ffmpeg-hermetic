//! FFmpeg's configure dependency resolution and Makefile object selection, replayed at
//! build-graph time over the data tools/ffmpeg_gen.py extracts into gen/ffmpeg/configure.zig.
const std = @import("std");
pub const data = @import("../../gen/ffmpeg/configure.zig");

/// A configure variable: `yes`, `no`, or never assigned.
pub const Value = enum { unset, yes, no };

pub const Decl = struct {
    name: []const u8,
    deps: []const []const u8 = &.{},
    deps_any: []const []const u8 = &.{},
    conflict: []const []const u8 = &.{},
    select: []const []const u8 = &.{},
    suggest: []const []const u8 = &.{},
    @"if": []const []const u8 = &.{},
    if_any: []const []const u8 = &.{},
};

pub const Default = struct { []const u8, Value };

pub const ComponentFile = struct {
    path: []const u8,
    struct_name: []const u8,
    array: []const u8,
    /// Component name and the `ff_` symbol it adds to the list.
    entries: []const struct { []const u8, []const u8 },
    /// Symbols configure appends unconditionally.
    tail: []const []const u8,
};

pub const Kind = enum { c, cpp, objc, gas, nasm, rc, cuda, opencl, generated };

/// Source path, kind, the arch or intrinsics directory whose Makefile lists it ("" for the
/// library's own), names that must all be enabled (`!` negates), and extra include dirs.
pub const Object = struct { []const u8, Kind, []const u8, []const []const u8, []const []const u8 };

pub const Library = struct {
    name: []const u8,
    headers: []const []const u8,
    built_headers: []const []const u8,
    objects: []const Object,
};

/// Names configure sets only while probing an enabled library, as the pinned versions answer.
const library_probes = [_]struct { []const u8, []const []const u8 }{
    .{ "zlib", &.{"zlib_gzip"} },
    .{ "libdrm", &.{ "linux_dma_buf_h", "libdrm_getfb2" } },
    .{ "ffnvcodec", &.{"cuda"} },
    .{ "nvenc", &.{"NV_ENC_PIC_PARAMS_AV1"} },
    .{ "nvdec", &.{"CUVIDAV1PICPARAMS"} },
    .{ "cuvid", &.{"CUVIDAV1PICPARAMS"} },
    .{ "libx264", &.{"libx264_hdr10"} },
    .{ "vaapi", &.{
        "vaapi_1",
        "VAPictureParameterBufferHEVC",
        "VAPictureParameterBufferVVC",
        "VADecPictureParameterBufferVP9_bit_depth",
        "VADecPictureParameterBufferAV1_bit_depth_idx",
        "VAProcFilterParameterBufferHDRToneMapping",
        "VAProcPipelineCaps_rotation_flags",
        "VAProcPipelineCaps_blend_flags",
        "VAEncPictureParameterBufferHEVC",
        "VAEncPictureParameterBufferJPEG",
        "VAEncPictureParameterBufferVP8",
        "VAEncPictureParameterBufferVP9",
        "VAEncPictureParameterBufferAV1",
    } },
};

/// configure's probe-phase rules: the second set is disabled unless all of the first are enabled.
const disable_unless = [_]struct { []const []const u8, []const []const u8 }{
    .{ &.{ "zlib_gzip", "gzip" }, &.{ "shader_compression", "resource_compression" } },
};

pub const Options = struct {
    gpl: bool,
    version3: bool = false,
    /// External and hwaccel libraries to enable, by configure name (`libvpx`, `vaapi`, ...).
    libraries: []const []const u8,
};

pub const State = struct {
    gpa: std.mem.Allocator,
    values: std.StringHashMapUnmanaged(Value) = .empty,
    decls: std.StringHashMapUnmanaged(*const Decl) = .empty,
    /// false while a name's dependencies are being checked, true once done.
    checked: std.StringHashMapUnmanaged(bool) = .empty,
    /// Printed key (`HAVE_FOO`) to configure name, for every printed list.
    keys: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// The state after configure parses the base options, before any probe runs.
    pub fn init(gpa: std.mem.Allocator) State {
        var s: State = .{ .gpa = gpa };
        for (&data.decls) |*d| s.decls.put(gpa, d.name, d) catch @panic("OOM");
        for (data.defaults) |d| s.put(d[0], d[1]);
        for ([_]struct { []const u8, []const []const u8 }{
            .{ "ARCH_", data.lists.arch_list },
            .{ "HAVE_", data.lists.have_list },
            .{ "CONFIG_", data.lists.config_list },
            .{ "CONFIG_", data.lists.config_extra },
            .{ "CONFIG_", data.lists.all_components },
        }) |l| for (l[1]) |name| s.keys.put(gpa, key(gpa, l[0], name), name) catch @panic("OOM");
        return s;
    }

    pub fn get(s: *const State, name: []const u8) Value {
        return s.values.get(name) orelse .unset;
    }

    pub fn put(s: *State, name: []const u8, v: Value) void {
        s.values.put(s.gpa, name, v) catch @panic("OOM");
    }

    pub fn enabled(s: *const State, name: []const u8) bool {
        return s.get(name) == .yes;
    }

    fn disabled(s: *const State, name: []const u8) bool {
        return s.get(name) == .no;
    }

    /// Sets probe results from a struct of printed keys (`HAVE_FOO = true`) or bare configure
    /// names (`libm = true`). Every ARCH_ and HAVE_ name must be given.
    pub fn setFacts(s: *State, facts: anytype) void {
        var given: std.StringHashMapUnmanaged(void) = .empty;
        const info = @typeInfo(@TypeOf(facts)).@"struct";
        inline for (info.field_names) |field| {
            const name = s.keys.get(field) orelse field;
            if (s.keys.get(field) == null and std.ascii.isUpper(field[0])) {
                std.debug.panic("FFmpeg config key {s} is not in configure's lists", .{field});
            }
            s.put(name, if (@field(facts, field)) .yes else .no);
            given.put(s.gpa, name, {}) catch @panic("OOM");
        }
        for ([_][]const []const u8{ data.lists.arch_list, data.lists.have_list }) |list| {
            for (list) |name| if (!given.contains(name)) {
                std.debug.panic("build/ffmpeg/config.zig gives no value for {s}", .{name});
            };
        }
    }

    /// Applies the license and library options, then the probe-phase logic that depends on them.
    pub fn configure(s: *State, o: Options) void {
        if (o.gpl) {
            s.put("gpl", .yes);
            s.put("lgpl_gpl", .yes);
        }
        if (o.version3) {
            s.put("version3", .yes);
            s.put(if (o.gpl) "gplv3" else "lgplv3", .yes);
        }
        const lists = data.lists;
        for (o.libraries) |lib| {
            if (!contains(&.{ lists.external_library_list, lists.hwaccel_library_list, lists.external_autodetect_library_list, lists.hwaccel_autodetect_library_list }, lib)) {
                std.debug.panic("{s} is not an FFmpeg external or hwaccel library", .{lib});
            }
            if (!o.gpl and contains(&.{lists.external_library_gpl_list}, lib)) {
                std.debug.panic("FFmpeg's {s} needs -Dgpl", .{lib});
            }
            if (o.gpl and !o.version3 and std.mem.eql(u8, lib, "openssl")) {
                std.debug.panic("FFmpeg accepts OpenSSL 3 in GPL builds only with -Dversion3", .{});
            }
            if (!o.version3 and contains(&.{ lists.external_library_version3_list, lists.external_library_gplv3_list }, lib)) {
                std.debug.panic("FFmpeg's {s} needs -Dversion3", .{lib});
            }
            if (!o.gpl and contains(&.{lists.external_library_gplv3_list}, lib)) {
                std.debug.panic("FFmpeg's {s} needs -Dgpl", .{lib});
            }
            if (contains(&.{ lists.external_library_nonfree_list, lists.hwaccel_library_nonfree_list }, lib)) {
                std.debug.panic("FFmpeg's {s} needs a nonfree license, which this build does not offer", .{lib});
            }
            s.put(lib, .yes);
        }
        for (library_probes) |p| for (p[1]) |name| s.put(name, .unset);
        for (library_probes) |p| if (s.enabled(p[0])) for (p[1]) |name| s.put(name, .yes);
        for (disable_unless) |r| {
            for (r[0]) |need| if (!s.enabled(need)) {
                for (r[1]) |name| s.put(name, .no);
                break;
            };
        }
        s.put("frame_thread_encoder", .yes);
    }

    /// configure's `check_deps $CONFIG_LIST $CONFIG_EXTRA $HAVE_LIST $ALL_COMPONENTS`.
    pub fn resolve(s: *State) void {
        s.checkDeps(data.lists.config_list);
        s.checkDeps(data.lists.config_extra);
        s.checkDeps(data.lists.have_list);
        s.checkDeps(data.lists.all_components);
    }

    fn checkDeps(s: *State, names: []const []const u8) void {
        for (names) |cfg| {
            if (s.checked.get(cfg)) |done| {
                if (done) continue;
                std.debug.panic("circular FFmpeg dependency for {s}", .{cfg});
            }
            const d = s.decls.get(cfg) orelse {
                s.checked.put(s.gpa, cfg, true) catch @panic("OOM");
                continue;
            };
            s.checked.put(s.gpa, cfg, false) catch @panic("OOM");
            inline for (.{ "deps", "deps_any", "conflict", "select", "suggest", "if", "if_any" }) |f| s.checkDeps(@field(d, f));

            if (d.@"if".len > 0 and s.all(d.@"if")) s.enableWeak(cfg);
            if (d.if_any.len > 0 and s.any(d.if_any)) s.enableWeak(cfg);
            if (!s.all(d.deps)) s.put(cfg, .no);
            if (d.deps_any.len > 0 and !s.any(d.deps_any)) s.put(cfg, .no);
            for (d.conflict) |c| if (!s.disabled(c)) s.put(cfg, .no);
            for (d.select) |c| if (s.disabled(c)) s.put(cfg, .no);
            if (s.enabled(cfg)) {
                for (d.select) |n| s.enableDeepWeak(n);
                for (d.suggest) |n| s.enableDeepWeak(n);
            }
            s.checked.put(s.gpa, cfg, true) catch @panic("OOM");
        }
    }

    fn all(s: *const State, names: []const []const u8) bool {
        for (names) |n| if (!s.enabled(n)) return false;
        return true;
    }

    fn any(s: *const State, names: []const []const u8) bool {
        for (names) |n| if (s.enabled(n)) return true;
        return false;
    }

    fn enableWeak(s: *State, name: []const u8) void {
        if (s.get(name) == .unset) s.put(name, .yes);
    }

    fn doEnableDeep(s: *State, name: []const u8) void {
        if (s.enabled(name)) return;
        const d = s.decls.get(name) orelse return;
        for (d.select) |n| s.doEnableDeep(n);
        for (d.select) |n| s.put(n, .yes);
        for (d.suggest) |n| s.enableDeepWeak(n);
    }

    fn enableDeepWeak(s: *State, name: []const u8) void {
        if (s.disabled(name)) return;
        s.doEnableDeep(name);
        s.enableWeak(name);
    }

    /// Adds `PREFIX_NAME` booleans for configure's printed lists, in configure's order.
    pub fn define(s: *const State, header: *std.Build.Step.ConfigHeader) void {
        for ([_]struct { []const u8, []const []const u8 }{
            .{ "ARCH_", data.lists.arch_list },
            .{ "HAVE_", data.lists.have_list },
            .{ "CONFIG_", data.lists.config_list },
            .{ "CONFIG_", data.lists.config_extra },
        }) |l| for (l[1]) |name| header.addValue(key(s.gpa, l[0], name), bool, s.enabled(name));
    }

    /// config_components.h, or config_components.asm with `asm`.
    pub fn componentsFile(s: *const State, comptime asm_style: bool) []const u8 {
        var out: std.Io.Writer.Allocating = .init(s.gpa);
        const w = &out.writer;
        if (asm_style) {
            w.writeAll("; Automatically generated by configure - do not modify!\n") catch @panic("OOM");
        } else {
            w.writeAll("/* Automatically generated by configure - do not modify! */\n#ifndef FFMPEG_CONFIG_COMPONENTS_H\n#define FFMPEG_CONFIG_COMPONENTS_H\n") catch @panic("OOM");
        }
        for (data.lists.all_components) |name| {
            w.print("{s} {s} {d}\n", .{ if (asm_style) "%define" else "#define", key(s.gpa, "CONFIG_", name), @intFromBool(s.enabled(name)) }) catch @panic("OOM");
        }
        if (!asm_style) w.writeAll("#endif /* FFMPEG_CONFIG_COMPONENTS_H */\n") catch @panic("OOM");
        return out.written();
    }

    /// One of the `*_list.c` files print_enabled_components writes.
    pub fn listFile(s: *const State, f: ComponentFile) []const u8 {
        var out: std.Io.Writer.Allocating = .init(s.gpa);
        const w = &out.writer;
        w.print("static const {s} * const {s}[] = {{\n", .{ f.struct_name, f.array }) catch @panic("OOM");
        for (f.entries) |e| if (s.enabled(e[0])) w.print("    &ff_{s},\n", .{e[1]}) catch @panic("OOM");
        for (f.tail) |sym| w.print("    &ff_{s},\n", .{sym}) catch @panic("OOM");
        w.writeAll("    NULL };\n") catch @panic("OOM");
        return out.written();
    }

    fn on(s: *const State, cond: []const u8) bool {
        if (cond[0] == '!') return !s.enabled(cond[1..]);
        return s.enabled(cond);
    }

    /// The sources `lib` builds: objects listed by its own Makefile or by the Makefiles of
    /// `dirs` (the arch and intrinsics directories), whose conditions all hold.
    pub fn sources(s: *const State, lib: Library, dirs: []const []const u8) Sources {
        var seen: std.StringArrayHashMapUnmanaged(Object) = .empty;
        for (lib.objects) |o| {
            if (o[2].len > 0 and !contains(&.{dirs}, o[2])) continue;
            const wanted = for (o[3]) |cond| {
                if (!s.on(cond)) break false;
            } else true;
            if (wanted) seen.put(s.gpa, o[0], o) catch @panic("OOM");
        }
        const objs = s.gpa.dupe(Object, seen.values()) catch @panic("OOM");
        std.mem.sort(Object, objs, {}, struct {
            fn lt(_: void, a: Object, b: Object) bool {
                return std.mem.lessThan(u8, a[0], b[0]);
            }
        }.lt);
        var out: Sources = .{};
        var groups: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
        for (objs) |o| {
            const list = switch (o[1]) {
                .c => blk: {
                    const g = groups.getOrPut(s.gpa, std.mem.join(s.gpa, " ", o[4]) catch @panic("OOM")) catch @panic("OOM");
                    if (!g.found_existing) {
                        g.value_ptr.* = .empty;
                        out.c.append(s.gpa, .{ .includes = o[4], .files = &.{} }) catch @panic("OOM");
                    }
                    break :blk g.value_ptr;
                },
                .nasm => &out.nasm,
                .gas => &out.gas,
                .cuda => &out.cuda,
                .opencl => &out.opencl,
                else => &out.unsupported,
            };
            list.append(s.gpa, o[0]) catch @panic("OOM");
        }
        for (out.c.items, groups.values()) |*g, files| g.files = files.items;
        std.mem.sort(Group, out.c.items, {}, struct {
            fn lt(_: void, a: Group, b: Group) bool {
                const n = @min(a.includes.len, b.includes.len);
                for (a.includes[0..n], b.includes[0..n]) |x, y| {
                    if (!std.mem.eql(u8, x, y)) return std.mem.lessThan(u8, x, y);
                }
                return a.includes.len < b.includes.len;
            }
        }.lt);
        return out;
    }
};

pub const Group = struct {
    /// Extra include dirs, relative to the FFmpeg tree.
    includes: []const []const u8,
    files: []const []const u8,
};

pub const Sources = struct {
    c: std.ArrayList(Group) = .empty,
    nasm: std.ArrayList([]const u8) = .empty,
    gas: std.ArrayList([]const u8) = .empty,
    cuda: std.ArrayList([]const u8) = .empty,
    /// OpenCL kernels, embedded as C strings.
    opencl: std.ArrayList([]const u8) = .empty,
    /// Objects this build cannot compile (C++, Objective-C, resources, generated shaders).
    unsupported: std.ArrayList([]const u8) = .empty,
};

fn key(gpa: std.mem.Allocator, prefix: []const u8, name: []const u8) []const u8 {
    const k = std.mem.concat(gpa, u8, &.{ prefix, name }) catch @panic("OOM");
    _ = std.ascii.upperString(k, k);
    return k;
}

fn contains(lists: []const []const []const u8, name: []const u8) bool {
    for (lists) |list| for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}
