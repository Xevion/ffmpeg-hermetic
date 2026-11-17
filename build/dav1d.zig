const std = @import("std");
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "dav1d",
    .version = "1.5.4",
    .licenses = &.{"COPYING"},
    .ffmpeg = &.{"libdav1d"},
    .system_libs = .{ .linux = &.{ "pthread", "dl" } },
};

const version = meta.version;

pub fn build(c: Ctx, nasm: Nasm) ?Ctx.Output {
    const b = c.b;
    const t = c.target.result;
    const src = c.upstream("dav1d");
    const x86 = t.cpu.arch.isX86();
    const x86_64 = t.cpu.arch == .x86_64;
    const aarch64 = t.cpu.arch == .aarch64;
    const linux = c.os() == .linux;
    const windows = c.isWindows();
    const darwin = t.os.tag.isDarwin();
    // C callers reach the asm through a leading underscore on these ABIs.
    const prefix = darwin or (windows and t.cpu.arch == .x86);
    const arm_asm = aarch64 and !windows;
    const asm_enabled = x86 or arm_asm;

    const config = b.addConfigHeader(.{ .include_path = "config.h" }, .{
        .ARCH_AARCH64 = b10(aarch64),
        .ARCH_ARM = 0,
        .ARCH_LOONGARCH = 0,
        .ARCH_LOONGARCH32 = 0,
        .ARCH_LOONGARCH64 = 0,
        .ARCH_PPC64LE = 0,
        .ARCH_RISCV = 0,
        .ARCH_RV32 = 0,
        .ARCH_RV64 = 0,
        .ARCH_X86 = b10(x86),
        .ARCH_X86_32 = b10(t.cpu.arch == .x86),
        .ARCH_X86_64 = b10(x86_64),
        .CONFIG_16BPC = 1,
        .CONFIG_8BPC = 1,
        .CONFIG_LOG = 1,
        .ENDIANNESS_BIG = b10(t.cpu.arch.endian() == .big),
        .HAVE_ALIGNED_ALLOC = b10(!windows),
        .HAVE_ASM = b10(asm_enabled),
        .HAVE_AS_ARCHEXT_DOTPROD_DIRECTIVE = b10(arm_asm),
        .HAVE_AS_ARCHEXT_I8MM_DIRECTIVE = b10(arm_asm),
        .HAVE_AS_ARCHEXT_SVE2_DIRECTIVE = b10(arm_asm),
        .HAVE_AS_ARCHEXT_SVE_DIRECTIVE = b10(arm_asm),
        .HAVE_AS_ARCH_DIRECTIVE = b10(arm_asm),
        // clang's assembler has no .func/.endfunc.
        .HAVE_AS_FUNC = 0,
        .HAVE_C11_GENERIC = 1,
        .HAVE_CLOCK_GETTIME = b10(!windows),
        .HAVE_DLSYM = b10(linux),
        .HAVE_DOTPROD = b10(arm_asm),
        .HAVE_ELF_AUX_INFO = 0,
        .HAVE_GETAUXVAL = b10(arm_asm and linux),
        .HAVE_I8MM = b10(arm_asm),
        .HAVE_IO_H = b10(windows),
        .HAVE_MEMALIGN = b10(linux),
        .HAVE_POSIX_MEMALIGN = b10(!windows),
        .HAVE_PTHREAD_GETAFFINITY_NP = b10(linux),
        .HAVE_PTHREAD_NP_H = 0,
        .HAVE_PTHREAD_SETAFFINITY_NP = b10(linux),
        .HAVE_PTHREAD_SETNAME_NP = b10(linux or darwin),
        .HAVE_PTHREAD_SET_NAME_NP = 0,
        .HAVE_SIGACTION = b10(!windows),
        .HAVE_SVE = b10(arm_asm),
        .HAVE_SVE2 = b10(arm_asm),
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_UNISTD_H = b10(!c.isMsvc()),
        .PIC = if (arm_asm) @as(?i64, 3) else null,
        .PREFIX = if (prefix) @as(?i64, 1) else null,
        .TRIM_DSP_FUNCTIONS = 1,
        .UNICODE = if (windows) @as(?i64, 1) else null,
        ._UNICODE = if (windows) @as(?i64, 1) else null,
        ._CRT_DECLARE_NONSTDC_NAMES = if (windows) @as(?i64, 1) else null,
        .__USE_MINGW_ANSI_STDIO = if (windows) @as(?i64, 1) else null,
    });

    // sdkddkver.h pastes the value into a token, so it must stay hexadecimal.
    if (windows) config.addIdent("_WIN32_WINNT", "0x0601");

    const generated = b.addWriteFiles();
    _ = generated.add("vcs_version.h", "#define DAV1D_VERSION \"" ++ version ++ "\"\n");
    if (x86) {
        _ = generated.add("config.asm", b.fmt(
            \\%define ARCH_X86_32 {d}
            \\%define ARCH_X86_64 {d}
            \\%define FORCE_VEX_ENCODING 0
            \\%define PIC 1
            \\{s}%define STACK_ALIGNMENT {d}
            \\%define private_prefix dav1d
            \\
        , .{
            b10(t.cpu.arch == .x86),
            b10(x86_64),
            // x86inc tests PREFIX with %ifdef, so it is present only when wanted.
            if (prefix) "%define PREFIX 1\n" else "",
            @as(u8, if (x86_64 or linux or darwin) 16 else 4),
        }));
    }

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{ "-DNDEBUG", "-D_FILE_OFFSET_BITS=64", "-ffast-math", "-fomit-frame-pointer", "-fvisibility=hidden" }) catch @panic("OOM");
    if (linux) flags.append(b.allocator, "-D_GNU_SOURCE") catch @panic("OOM");
    if (aarch64) flags.append(b.allocator, "-fno-align-functions") catch @panic("OOM");

    const setup: Ctx.Setup = .{
        .config_headers = &.{config},
        .includes = std.mem.concat(b.allocator, std.Build.LazyPath, &.{
            &.{generated.getDirectory()},
            c.includeDirs(src.path(""), &.{ "", "include", "include/dav1d", "src" }),
        }) catch @panic("OOM"),
    };

    const mod = c.module(.{});
    setup.apply(mod);
    mod.addCSourceFiles(.{ .root = src.path(""), .files = &common, .flags = flags.items });
    if (x86) mod.addCSourceFiles(.{ .root = src.path(""), .files = &.{"src/x86/cpu.c"}, .flags = flags.items });
    if (arm_asm) {
        mod.addCSourceFiles(.{ .root = src.path(""), .files = &.{"src/arm/cpu.c"}, .flags = flags.items });
        // Clang accepts every .arch level and extension directive dav1d probes for.
        const as_flags = std.mem.concat(b.allocator, []const u8, &.{ flags.items, &.{"-DAS_ARCH_LEVEL=armv8.6-a+crc"} }) catch @panic("OOM");
        mod.addCSourceFiles(.{ .root = src.path(""), .files = &aarch64_asm, .flags = as_flags });
    }
    if (windows) mod.addCSourceFiles(.{ .root = src.path(""), .files = &.{"src/win32/thread.c"}, .flags = flags.items });

    for ([_][]const u8{ "8", "16" }) |depth| {
        c.addSources(mod, b.fmt("dav1d_bitdepth_{s}", .{depth}), .{
            .setup = setup,
            .groups = &.{.{
                .root = src.path(""),
                .files = &bitdepth,
                .flags = std.mem.concat(b.allocator, []const u8, &.{ flags.items, &.{b.fmt("-DBITDEPTH={s}", .{depth})} }) catch @panic("OOM"),
            }},
        });
    }

    if (x86) {
        nasm.addFiles(c, mod, .{
            .root = src.path(""),
            .files = &x86_asm,
            .include_dirs = &.{ src.path("src"), generated.getDirectory() },
        });
    }

    const lib = c.staticLibrary("dav1d", mod);
    lib.installHeadersDirectory(src.path("include/dav1d"), "dav1d", .{});
    return c.single(lib);
}

fn b10(v: bool) u1 {
    return @intFromBool(v);
}

const common = [_][]const u8{
    "src/cdf.c",            "src/cpu.c",     "src/ctx.c",         "src/data.c",   "src/decode.c",
    "src/dequant_tables.c", "src/getbits.c", "src/intra_edge.c",  "src/itx_1d.c", "src/lf_mask.c",
    "src/lib.c",            "src/log.c",     "src/mem.c",         "src/msac.c",   "src/obu.c",
    "src/pal.c",            "src/picture.c", "src/qm.c",          "src/ref.c",    "src/refmvs.c",
    "src/scan.c",           "src/tables.c",  "src/thread_task.c", "src/warpmv.c", "src/wedge.c",
};

const bitdepth = [_][]const u8{
    "src/cdef_apply_tmpl.c",    "src/cdef_tmpl.c",            "src/fg_apply_tmpl.c", "src/filmgrain_tmpl.c",
    "src/ipred_prepare_tmpl.c", "src/ipred_tmpl.c",           "src/itx_tmpl.c",      "src/lf_apply_tmpl.c",
    "src/loopfilter_tmpl.c",    "src/looprestoration_tmpl.c", "src/lr_apply_tmpl.c", "src/mc_tmpl.c",
    "src/recon_tmpl.c",
};

const x86_asm = [_][]const u8{
    "src/x86/cpuid.asm",                 "src/x86/msac.asm",                   "src/x86/pal.asm",
    "src/x86/refmvs.asm",                "src/x86/cdef_avx2.asm",              "src/x86/cdef_avx512.asm",
    "src/x86/cdef_sse.asm",              "src/x86/cdef16_avx2.asm",            "src/x86/cdef16_avx512.asm",
    "src/x86/cdef16_sse.asm",            "src/x86/filmgrain_avx2.asm",         "src/x86/filmgrain_avx512.asm",
    "src/x86/filmgrain_sse.asm",         "src/x86/filmgrain16_avx2.asm",       "src/x86/filmgrain16_avx512.asm",
    "src/x86/filmgrain16_sse.asm",       "src/x86/ipred_avx2.asm",             "src/x86/ipred_avx512.asm",
    "src/x86/ipred_sse.asm",             "src/x86/ipred16_avx2.asm",           "src/x86/ipred16_avx512.asm",
    "src/x86/ipred16_sse.asm",           "src/x86/itx_avx2.asm",               "src/x86/itx_avx512.asm",
    "src/x86/itx_sse.asm",               "src/x86/itx16_avx2.asm",             "src/x86/itx16_avx512.asm",
    "src/x86/itx16_sse.asm",             "src/x86/loopfilter_avx2.asm",        "src/x86/loopfilter_avx512.asm",
    "src/x86/loopfilter_sse.asm",        "src/x86/loopfilter16_avx2.asm",      "src/x86/loopfilter16_avx512.asm",
    "src/x86/loopfilter16_sse.asm",      "src/x86/looprestoration_avx2.asm",   "src/x86/looprestoration_avx512.asm",
    "src/x86/looprestoration_sse.asm",   "src/x86/looprestoration16_avx2.asm", "src/x86/looprestoration16_avx512.asm",
    "src/x86/looprestoration16_sse.asm", "src/x86/mc_avx2.asm",                "src/x86/mc_avx512.asm",
    "src/x86/mc_sse.asm",                "src/x86/mc16_avx2.asm",              "src/x86/mc16_avx512.asm",
    "src/x86/mc16_sse.asm",
};

const aarch64_asm = [_][]const u8{
    "src/arm/64/itx.S",               "src/arm/64/looprestoration_common.S", "src/arm/64/msac.S",       "src/arm/64/refmvs.S",
    "src/arm/64/cdef.S",              "src/arm/64/filmgrain.S",              "src/arm/64/ipred.S",      "src/arm/64/loopfilter.S",
    "src/arm/64/looprestoration.S",   "src/arm/64/mc.S",                     "src/arm/64/mc_dotprod.S", "src/arm/64/cdef16.S",
    "src/arm/64/filmgrain16.S",       "src/arm/64/ipred16.S",                "src/arm/64/itx16.S",      "src/arm/64/loopfilter16.S",
    "src/arm/64/looprestoration16.S", "src/arm/64/mc16.S",                   "src/arm/64/mc16_sve.S",
};
