//! FFmpeg's probe results for a target, and the config.h, config.asm and avconfig.h printed
//! from the resolved configure state.
//!
//! Started from allyourcodebase/ffmpeg's predicates and checked key by key against the
//! configure output in gen/ffmpeg/<target>-<variant>/oracle by tools/check_config.py.
const std = @import("std");
const Ctx = @import("../Ctx.zig");
const resolve = @import("resolve.zig");

pub const Options = struct {
    gpl: bool,
    version3: bool,
    /// Enabled external libraries, by configure name, for FFMPEG_CONFIGURATION.
    libraries: []const []const u8,
};

pub const Headers = struct {
    config_h: *std.Build.Step.ConfigHeader,
    config_asm: *std.Build.Step.ConfigHeader,
    avconfig_h: *std.Build.Step.ConfigHeader,
};

/// Sets what configure's probes would find for the target: every ARCH_ and HAVE_ value, plus
/// the few CONFIG_ and unprinted names configure sets while probing.
pub fn apply(c: Ctx, s: *resolve.State) void {
    const t = c.target.result;
    const x86 = t.cpu.arch.isX86();
    // Like the x86 keys, aarch64 extension keys mean assembler support behind runtime detection.
    const a64 = t.cpu.arch.isAARCH64();
    const msvc = t.abi == .msvc;
    const windows = t.os.tag == .windows;
    const linux = t.os.tag == .linux;
    const darwin = t.os.tag.isDarwin();
    _ = .{ msvc, windows, linux, darwin };

    @setEvalBranchQuota(20000);
    const common = .{
        .ARCH_AARCH64 = t.cpu.arch.isAARCH64(),
        .ARCH_ARM = t.cpu.arch.isArm(),
        .ARCH_IA64 = false,
        .ARCH_LOONGARCH = switch (t.cpu.arch) {
            .loongarch32, .loongarch64 => true,
            else => false,
        },
        .ARCH_LOONGARCH32 = t.cpu.arch == .loongarch32,
        .ARCH_LOONGARCH64 = t.cpu.arch == .loongarch64,
        .ARCH_M68K = t.cpu.arch == .m68k,
        .ARCH_MIPS = switch (t.cpu.arch) {
            .mips, .mipsel => true,
            else => false,
        },
        .ARCH_MIPS64 = switch (t.cpu.arch) {
            .mips64, .mips64el => true,
            else => false,
        },
        .ARCH_PARISC = false,
        .ARCH_PPC = t.cpu.arch.isPowerPC(),
        .ARCH_PPC64 = t.cpu.arch.isPowerPC64(),
        .ARCH_RISCV = t.cpu.arch.isRISCV(),
        .ARCH_S390 = t.cpu.arch == .s390x,
        .ARCH_SPARC = t.cpu.arch.isSPARC(),
        .ARCH_SPARC64 = t.cpu.arch == .sparc64,
        .ARCH_TILEGX = false,
        .ARCH_TILEPRO = false,
        .ARCH_WASM = t.cpu.arch.isWasm(),
        .ARCH_X86 = t.cpu.arch.isX86(),
        .ARCH_X86_32 = false,
        .ARCH_X86_64 = x86,
        .HAVE_ARMV5TE = have_arm_feat(t, .has_v5te),
        .HAVE_ARMV6 = have_arm_feat(t, .has_v6),
        .HAVE_ARMV6T2 = have_arm_feat(t, .has_v6t2),
        .HAVE_ARMV8 = have_arm_feat(t, .has_v8) or a64,
        .HAVE_ARM_CRC = have_arm_feat(t, .crc) or a64,
        .HAVE_DOTPROD = have_arm_feat(t, .dotprod) or a64,
        .HAVE_I8MM = have_arm_feat(t, .i8mm) or a64,
        .HAVE_NEON = have_arm_feat(t, .neon) or have_aarch64_feat(t, .neon),
        .HAVE_VFP = have_arm_feat(t, .vfp2),
        .HAVE_VFPV3 = have_arm_feat(t, .vfp3),
        .HAVE_SETEND = false,
        .HAVE_SVE = a64,
        .HAVE_SVE2 = a64,
        .HAVE_SME = a64,
        .HAVE_SME_I16I64 = a64,
        .HAVE_SME2 = a64,
        .HAVE_ALTIVEC = have_ppc_feat(t, .altivec),
        .HAVE_DCBZL = false,
        .HAVE_LDBRX = have_ppc_feat(t, .ldbrx),
        .HAVE_POWER8 = have_ppc_feat(t, .power8_vector),
        .HAVE_PPC4XX = have_ppc_feat(t, .ppc4xx),
        .HAVE_VEC_XL = false,
        .HAVE_VSX = have_ppc_feat(t, .vsx),
        .HAVE_RV = false,
        .HAVE_RVV = false,
        .HAVE_RV_ZICBOP = true,
        .HAVE_RV_ZVBB = false,
        .HAVE_SIMD128 = have_wasm_feat(t, .simd128),
        .HAVE_AESNI = x86,
        .HAVE_CLMUL = true,
        .HAVE_AMD3DNOW = true,
        .HAVE_AMD3DNOWEXT = true,
        .HAVE_AVX = x86,
        .HAVE_AVX2 = x86,
        .HAVE_AVX512 = x86,
        .HAVE_AVX512ICL = x86,
        .HAVE_FMA3 = x86,
        .HAVE_FMA4 = x86,
        .HAVE_MMX = x86,
        .HAVE_MMXEXT = x86,
        .HAVE_SSE = x86,
        .HAVE_SSE2 = x86,
        .HAVE_SSE3 = x86,
        .HAVE_SSE4 = x86,
        .HAVE_SSE42 = x86,
        .HAVE_SSSE3 = x86,
        .HAVE_XOP = x86,
        .HAVE_I686 = x86,
        .HAVE_MIPSFPU = missing_mips_feat(t, .soft_float),
        .HAVE_MIPS32R2 = have_mips_feat(t, .mips32r2),
        .HAVE_MIPS32R5 = have_mips_feat(t, .mips32r5),
        .HAVE_MIPS64R2 = have_mips_feat(t, .mips64r2),
        .HAVE_MIPS32R6 = have_mips_feat(t, .mips32r6),
        .HAVE_MIPS64R6 = have_mips_feat(t, .mips64r6),
        .HAVE_MIPSDSP = have_mips_feat(t, .dsp),
        .HAVE_MIPSDSPR2 = have_mips_feat(t, .dspr2),
        .HAVE_MSA = have_mips_feat(t, .msa),
        .HAVE_LOONGSON2 = false,
        .HAVE_LOONGSON3 = false,
        .HAVE_MMI = false,
        .HAVE_LSX = false,
        .HAVE_LASX = false,
        .HAVE_ARMV5TE_EXTERNAL = have_arm_feat(t, .has_v5te),
        .HAVE_ARMV6_EXTERNAL = have_arm_feat(t, .has_v6),
        .HAVE_ARMV6T2_EXTERNAL = have_arm_feat(t, .has_v6t2),
        .HAVE_ARMV8_EXTERNAL = have_arm_feat(t, .has_v8) or a64,
        .HAVE_ARM_CRC_EXTERNAL = have_arm_feat(t, .crc) or have_aarch64_feat(t, .crc),
        .HAVE_DOTPROD_EXTERNAL = have_arm_feat(t, .dotprod) or have_aarch64_feat(t, .dotprod),
        .HAVE_I8MM_EXTERNAL = have_arm_feat(t, .i8mm) or have_aarch64_feat(t, .i8mm),
        .HAVE_NEON_EXTERNAL = have_arm_feat(t, .neon) or have_aarch64_feat(t, .neon),
        .HAVE_VFP_EXTERNAL = have_arm_feat(t, .vfp2),
        .HAVE_VFPV3_EXTERNAL = have_arm_feat(t, .vfp3),
        .HAVE_SETEND_EXTERNAL = false,
        .HAVE_SVE_EXTERNAL = have_aarch64_feat(t, .sve),
        .HAVE_SVE2_EXTERNAL = have_aarch64_feat(t, .sve2),
        .HAVE_SME_EXTERNAL = have_aarch64_feat(t, .sme),
        .HAVE_SME_I16I64_EXTERNAL = have_aarch64_feat(t, .sme_i16i64),
        .HAVE_SME2_EXTERNAL = have_aarch64_feat(t, .sme2),
        .HAVE_ALTIVEC_EXTERNAL = have_ppc_feat(t, .altivec),
        .HAVE_DCBZL_EXTERNAL = false,
        .HAVE_LDBRX_EXTERNAL = have_ppc_feat(t, .ldbrx),
        .HAVE_POWER8_EXTERNAL = have_ppc_feat(t, .power8_vector),
        .HAVE_PPC4XX_EXTERNAL = have_ppc_feat(t, .ppc4xx),
        .HAVE_VEC_XL_EXTERNAL = false,
        .HAVE_VSX_EXTERNAL = have_ppc_feat(t, .vsx),
        .HAVE_RV_EXTERNAL = false,
        .HAVE_RVV_EXTERNAL = false,
        .HAVE_RV_ZICBOP_EXTERNAL = false,
        .HAVE_RV_ZVBB_EXTERNAL = false,
        .HAVE_SIMD128_EXTERNAL = have_wasm_feat(t, .simd128),
        .HAVE_AESNI_EXTERNAL = x86,
        .HAVE_CLMUL_EXTERNAL = true,
        .HAVE_AMD3DNOW_EXTERNAL = false,
        .HAVE_AMD3DNOWEXT_EXTERNAL = false,
        .HAVE_AVX_EXTERNAL = x86,
        .HAVE_AVX2_EXTERNAL = x86,
        .HAVE_AVX512_EXTERNAL = x86,
        .HAVE_AVX512ICL_EXTERNAL = x86,
        .HAVE_FMA3_EXTERNAL = x86,
        .HAVE_FMA4_EXTERNAL = x86,
        .HAVE_MMX_EXTERNAL = x86,
        .HAVE_MMXEXT_EXTERNAL = x86,
        .HAVE_SSE_EXTERNAL = x86,
        .HAVE_SSE2_EXTERNAL = x86,
        .HAVE_SSE3_EXTERNAL = x86,
        .HAVE_SSE4_EXTERNAL = x86,
        .HAVE_SSE42_EXTERNAL = x86,
        .HAVE_SSSE3_EXTERNAL = x86,
        .HAVE_XOP_EXTERNAL = x86,
        .HAVE_I686_EXTERNAL = false,
        .HAVE_MIPSFPU_EXTERNAL = missing_mips_feat(t, .soft_float),
        .HAVE_MIPS32R2_EXTERNAL = have_mips_feat(t, .mips32r2),
        .HAVE_MIPS32R5_EXTERNAL = have_mips_feat(t, .mips32r5),
        .HAVE_MIPS64R2_EXTERNAL = have_mips_feat(t, .mips64r2),
        .HAVE_MIPS32R6_EXTERNAL = have_mips_feat(t, .mips32r6),
        .HAVE_MIPS64R6_EXTERNAL = have_mips_feat(t, .mips64r6),
        .HAVE_MIPSDSP_EXTERNAL = have_mips_feat(t, .dsp),
        .HAVE_MIPSDSPR2_EXTERNAL = have_mips_feat(t, .dspr2),
        .HAVE_MSA_EXTERNAL = have_mips_feat(t, .msa),
        .HAVE_LOONGSON2_EXTERNAL = false,
        .HAVE_LOONGSON3_EXTERNAL = false,
        .HAVE_MMI_EXTERNAL = false,
        .HAVE_LSX_EXTERNAL = false,
        .HAVE_LASX_EXTERNAL = false,
        .HAVE_ARMV5TE_INLINE = have_arm_feat(t, .has_v5te),
        .HAVE_ARMV6_INLINE = have_arm_feat(t, .has_v6),
        .HAVE_ARMV6T2_INLINE = have_arm_feat(t, .has_v6t2),
        .HAVE_ARMV8_INLINE = have_arm_feat(t, .has_v8) or a64,
        .HAVE_ARM_CRC_INLINE = have_arm_feat(t, .crc) or have_aarch64_feat(t, .crc),
        .HAVE_DOTPROD_INLINE = have_arm_feat(t, .dotprod) or have_aarch64_feat(t, .dotprod),
        .HAVE_I8MM_INLINE = have_arm_feat(t, .i8mm) or have_aarch64_feat(t, .i8mm),
        .HAVE_NEON_INLINE = have_arm_feat(t, .neon) or have_aarch64_feat(t, .neon),
        .HAVE_VFP_INLINE = have_arm_feat(t, .vfp2),
        .HAVE_VFPV3_INLINE = have_arm_feat(t, .vfp3),
        .HAVE_SETEND_INLINE = false,
        .HAVE_SVE_INLINE = have_aarch64_feat(t, .sve),
        .HAVE_SVE2_INLINE = have_aarch64_feat(t, .sve2),
        .HAVE_SME_INLINE = have_aarch64_feat(t, .sme),
        .HAVE_SME_I16I64_INLINE = have_aarch64_feat(t, .sme_i16i64),
        .HAVE_SME2_INLINE = have_aarch64_feat(t, .sme2),
        .HAVE_ALTIVEC_INLINE = have_ppc_feat(t, .altivec),
        .HAVE_DCBZL_INLINE = false,
        .HAVE_LDBRX_INLINE = have_ppc_feat(t, .ldbrx),
        .HAVE_POWER8_INLINE = have_ppc_feat(t, .power8_vector),
        .HAVE_PPC4XX_INLINE = have_ppc_feat(t, .ppc4xx),
        .HAVE_VEC_XL_INLINE = false,
        .HAVE_VSX_INLINE = have_ppc_feat(t, .vsx),
        .HAVE_RV_INLINE = false,
        .HAVE_RVV_INLINE = false,
        .HAVE_RV_ZICBOP_INLINE = false,
        .HAVE_RV_ZVBB_INLINE = false,
        .HAVE_SIMD128_INLINE = have_wasm_feat(t, .simd128),
        .HAVE_AESNI_INLINE = x86 and !msvc,
        .HAVE_CLMUL_INLINE = true,
        .HAVE_AMD3DNOW_INLINE = false,
        .HAVE_AMD3DNOWEXT_INLINE = false,
        .HAVE_AVX_INLINE = x86 and !msvc,
        .HAVE_AVX2_INLINE = x86 and !msvc,
        .HAVE_AVX512_INLINE = x86 and !msvc,
        .HAVE_AVX512ICL_INLINE = x86 and !msvc,
        .HAVE_FMA3_INLINE = x86 and !msvc,
        .HAVE_FMA4_INLINE = x86 and !msvc,
        .HAVE_MMX_INLINE = x86 and !msvc,
        .HAVE_MMXEXT_INLINE = x86 and !msvc,
        .HAVE_SSE_INLINE = x86 and !msvc,
        .HAVE_SSE2_INLINE = x86 and !msvc,
        .HAVE_SSE3_INLINE = x86 and !msvc,
        .HAVE_SSE4_INLINE = x86 and !msvc,
        .HAVE_SSE42_INLINE = x86 and !msvc,
        .HAVE_SSSE3_INLINE = x86 and !msvc,
        .HAVE_XOP_INLINE = x86 and !msvc,
        .HAVE_I686_INLINE = false,
        .HAVE_MIPSFPU_INLINE = missing_mips_feat(t, .soft_float),
        .HAVE_MIPS32R2_INLINE = have_mips_feat(t, .mips32r2),
        .HAVE_MIPS32R5_INLINE = have_mips_feat(t, .mips32r5),
        .HAVE_MIPS64R2_INLINE = have_mips_feat(t, .mips64r2),
        .HAVE_MIPS32R6_INLINE = have_mips_feat(t, .mips32r6),
        .HAVE_MIPS64R6_INLINE = have_mips_feat(t, .mips64r6),
        .HAVE_MIPSDSP_INLINE = have_mips_feat(t, .dsp),
        .HAVE_MIPSDSPR2_INLINE = have_mips_feat(t, .dspr2),
        .HAVE_MSA_INLINE = have_mips_feat(t, .msa),
        .HAVE_LOONGSON2_INLINE = false,
        .HAVE_LOONGSON3_INLINE = false,
        .HAVE_MMI_INLINE = false,
        .HAVE_LSX_INLINE = false,
        .HAVE_LASX_INLINE = false,
        .HAVE_ALIGNED_STACK = true,
        .HAVE_FAST_64BIT = true,
        .HAVE_FAST_CLZ = true,
        .HAVE_FAST_CMOV = x86,
        .HAVE_FAST_FLOAT16 = a64,
        .HAVE_SIMD_ALIGN_16 = true,
        .HAVE_SIMD_ALIGN_32 = x86,
        .HAVE_SIMD_ALIGN_64 = x86,
        .HAVE_MEMORYBARRIER = false,
        .HAVE_MM_EMPTY = x86,
        .HAVE_RDTSC = false,
        .HAVE_SEM_TIMEDWAIT = !darwin,
        .HAVE_INLINE_ASM = true,
        .HAVE_SYMVER = true,
        .HAVE_X86ASM = t.cpu.arch.isX86(),
        .HAVE_BIGENDIAN = t.cpu.arch.endian() == .big,
        .HAVE_FAST_UNALIGNED = fastUnalignedLoads(t),
        .HAVE_ARPA_INET_H = t.os.tag != .windows,
        .HAVE_ASM_HWPROBE_H = false,
        .HAVE_ASM_TYPES_H = true,
        .HAVE_CDIO_PARANOIA_H = false,
        .HAVE_CDIO_PARANOIA_PARANOIA_H = false,
        .HAVE_CUDA_H = false,
        .HAVE_DISPATCH_DISPATCH_H = darwin,
        .HAVE_DIRECT_H = windows,
        .HAVE_DIRENT_H = true,
        .HAVE_DXGIDEBUG_H = false,
        .HAVE_DXVA_H = windows,
        .HAVE_ES2_GL_H = false,
        .HAVE_GSM_H = false,
        .HAVE_IO_H = windows,
        .HAVE_LINUX_DMA_BUF_H = linux,
        .HAVE_LINUX_PERF_EVENT_H = linux,
        .HAVE_MALLOC_H = linux,
        .HAVE_POLL_H = t.os.tag != .windows,
        .HAVE_PTHREAD_NP_H = false,
        .HAVE_SYS_HWPROBE_H = false,
        .HAVE_SYS_PARAM_H = true,
        .HAVE_SYS_RESOURCE_H = true,
        .HAVE_SYS_SELECT_H = t.os.tag != .windows,
        .HAVE_SYS_SOUNDCARD_H = linux,
        .HAVE_SYS_TIME_H = true,
        .HAVE_SYS_UN_H = true,
        .HAVE_SYS_VIDEOIO_H = false,
        .HAVE_TERMIOS_H = true,
        .HAVE_UDPLITE_H = false,
        .HAVE_UNISTD_H = true,
        .HAVE_VALGRIND_VALGRIND_H = false,
        .HAVE_WINDOWS_H = windows,
        .HAVE_WINSOCK2_H = windows,
        .HAVE_INTRINSICS_NEON = have_arm_feat(t, .neon) or have_aarch64_feat(t, .neon),
        .HAVE_INTRINSICS_SSE2 = x86,
        .HAVE_ATANF = true,
        .HAVE_ATAN2F = true,
        .HAVE_CBRT = true,
        .HAVE_CBRTF = true,
        .HAVE_COPYSIGN = true,
        .HAVE_COSF = true,
        .HAVE_ERF = true,
        .HAVE_EXP2 = true,
        .HAVE_EXP2F = true,
        .HAVE_EXPF = true,
        .HAVE_HYPOT = true,
        .HAVE_ISFINITE = true,
        .HAVE_ISINF = true,
        .HAVE_ISNAN = true,
        .HAVE_LDEXPF = true,
        .HAVE_LLRINT = true,
        .HAVE_LLRINTF = true,
        .HAVE_LOG2 = true,
        .HAVE_LOG2F = true,
        .HAVE_LOG10F = true,
        .HAVE_LRINT = true,
        .HAVE_LRINTF = true,
        .HAVE_POWF = true,
        .HAVE_RINT = true,
        .HAVE_ROUND = true,
        .HAVE_ROUNDF = true,
        .HAVE_SINF = true,
        .HAVE_TRUNC = true,
        .HAVE_TRUNCF = true,
        .HAVE_DOS_PATHS = false,
        .HAVE_LIBC_MSVCRT = false,
        .HAVE_MMAL_PARAMETER_VIDEO_MAX_NUM_CALLBACKS = false,
        .HAVE_SECTION_DATA_REL_RO = linux,
        .HAVE_THREADS = true,
        .HAVE_UWP = false,
        .HAVE_WINRT = false,
        .HAVE_ACCESS = true,
        .HAVE_ALIGNED_MALLOC = false,
        .HAVE_ARC4RANDOM_BUF = switch (t.os.tag) {
            .dragonfly, .netbsd, .freebsd, .illumos, .openbsd, .serenity, .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
            else => false,
        },
        .HAVE_CLOCK_GETTIME = true,
        .HAVE_CLOSESOCKET = windows,
        .HAVE_COMMANDLINETOARGVW = false,
        .HAVE_ELF_AUX_INFO = false,
        .HAVE_FCNTL = t.os.tag != .windows,
        .HAVE_GETADDRINFO = true,
        .HAVE_GETAUXVAL = linux,
        .HAVE_GETENV = true,
        .HAVE_GETHRTIME = false,
        .HAVE_GETOPT = true,
        .HAVE_GETMODULEHANDLE = false,
        .HAVE_GETPROCESSAFFINITYMASK = false,
        .HAVE_GETPROCESSMEMORYINFO = false,
        .HAVE_GETPROCESSTIMES = false,
        .HAVE_GETRUSAGE = true,
        .HAVE_GETSTDHANDLE = false,
        .HAVE_GETSYSTEMTIMEASFILETIME = false,
        .HAVE_GETTIMEOFDAY = true,
        .HAVE_GLOB = t.os.tag != .windows,
        .HAVE_GLXGETPROCADDRESS = false,
        .HAVE_GMTIME_R = true,
        .HAVE_INET_ATON = true,
        .HAVE_ISATTY = true,
        .HAVE_KBHIT = false,
        .HAVE_LOCALTIME_R = true,
        .HAVE_LSTAT = t.os.tag != .windows,
        .HAVE_LZO1X_999_COMPRESS = false,
        .HAVE_MACH_ABSOLUTE_TIME = darwin,
        .HAVE_MAPVIEWOFFILE = false,
        .HAVE_MEMALIGN = linux,
        .HAVE_MKSTEMP = true,
        .HAVE_MMAP = t.os.tag != .windows,
        .HAVE_MPROTECT = true,
        .HAVE_NANOSLEEP = true,
        .HAVE_PEEKNAMEDPIPE = false,
        .HAVE_POSIX_MEMALIGN = t.os.tag != .windows,
        .HAVE_PRCTL = linux,
        .HAVE_PTHREAD_CANCEL = true,
        .HAVE_PTHREAD_SET_NAME_NP = false,
        .HAVE_PTHREAD_SETNAME_NP = darwin,
        .HAVE_SCHED_GETAFFINITY = linux,
        .HAVE_SECITEMIMPORT = darwin,
        .HAVE_SETCONSOLETEXTATTRIBUTE = false,
        .HAVE_SETCONSOLECTRLHANDLER = false,
        .HAVE_SETDLLDIRECTORY = false,
        .HAVE_SETMODE = false,
        .HAVE_SETRLIMIT = true,
        .HAVE_SLEEP = false,
        .HAVE_STRERROR_R = t.os.tag != .windows,
        .HAVE_SYSCONF = true,
        // configure finds sysctl() in libc stubs, but no supported libc ships <sys/sysctl.h>.
        .HAVE_SYSCTL = false,
        .HAVE_SYSCTLBYNAME = darwin,
        .HAVE_TEMPNAM = true,
        .HAVE_USLEEP = true,
        .HAVE_UTGETOSTYPEFROMSTRING = darwin,
        .HAVE_VIRTUALALLOC = windows,
        .HAVE_WGLGETPROCADDRESS = false,
        .HAVE_BCRYPT = false,
        .HAVE_VAAPI_DRM = false,
        .HAVE_VAAPI_X11 = false,
        .HAVE_VAAPI_WIN32 = false,
        .HAVE_VDPAU_X11 = false,
        .HAVE_PTHREADS = true,
        .HAVE_OS2THREADS = false,
        .HAVE_W32THREADS = false,
        .HAVE_AS_ARCH_DIRECTIVE = t.cpu.arch == .aarch64,
        .HAVE_AS_ARCHEXT_CRC_DIRECTIVE = a64,
        .HAVE_AS_ARCHEXT_DOTPROD_DIRECTIVE = t.cpu.arch == .aarch64,
        .HAVE_AS_ARCHEXT_I8MM_DIRECTIVE = t.cpu.arch == .aarch64,
        .HAVE_AS_ARCHEXT_SVE_DIRECTIVE = t.cpu.arch == .aarch64,
        .HAVE_AS_ARCHEXT_SVE2_DIRECTIVE = t.cpu.arch == .aarch64,
        .HAVE_AS_ARCHEXT_SME_DIRECTIVE = t.cpu.arch == .aarch64,
        .HAVE_AS_ARCHEXT_SME_I16I64_DIRECTIVE = t.cpu.arch == .aarch64,
        .HAVE_AS_ARCHEXT_SME2_DIRECTIVE = t.cpu.arch == .aarch64,
        .HAVE_AS_DN_DIRECTIVE = false,
        .HAVE_AS_FPU_DIRECTIVE = false,
        .HAVE_AS_FUNC = false,
        .HAVE_AS_OBJECT_ARCH = false,
        .HAVE_ASM_MOD_Q = false,
        .HAVE_BLOCKS_EXTENSION = darwin,
        .HAVE_EBP_AVAILABLE = t.cpu.arch == .x86_64,
        .HAVE_EBX_AVAILABLE = t.cpu.arch == .x86_64,
        .HAVE_GNU_AS = false,
        .HAVE_GNU_WINDRES = false,
        .HAVE_IBM_ASM = false,
        .HAVE_INLINE_ASM_DIRECT_SYMBOL_REFS = t.cpu.arch == .x86_64,
        .HAVE_INLINE_ASM_LABELS = true,
        .HAVE_INLINE_ASM_NONLOCAL_LABELS = true,
        .HAVE_PRAGMA_DEPRECATED = true,
        .HAVE_RSYNC_CONTIMEOUT = true,
        .HAVE_SYMVER_ASM_LABEL = t.ofmt == .elf,
        .HAVE_SYMVER_GNU_ASM = linux,
        .HAVE_VFP_ARGS = false,
        .HAVE_X86_32_7REGS = false,
        .HAVE_XFORM_ASM = false,
        .HAVE_XMM_CLOBBERS = x86 and !msvc,
        .HAVE_DPI_AWARENESS_CONTEXT = false,
        .HAVE_IDXGIOUTPUT5 = false,
        .HAVE___X_ABI_CWINDOWS_CGRAPHICS_CCAPTURE_CIGRAPHICSCAPTURESESSION5 = false,
        .HAVE_IDIRECT3DDXGIINTERFACEACCESS = false,
        .HAVE_KCMVIDEOCODECTYPE_HEVC = false,
        .HAVE_KCMVIDEOCODECTYPE_HEVCWITHALPHA = false,
        .HAVE_KCMVIDEOCODECTYPE_VP9 = false,
        .HAVE_KCMVIDEOCODECTYPE_AV1 = false,
        .HAVE_KCVPIXELFORMATTYPE_420YPCBCR10BIPLANARVIDEORANGE = false,
        .HAVE_KCVPIXELFORMATTYPE_422YPCBCR8BIPLANARVIDEORANGE = false,
        .HAVE_KCVPIXELFORMATTYPE_422YPCBCR10BIPLANARVIDEORANGE = false,
        .HAVE_KCVPIXELFORMATTYPE_422YPCBCR16BIPLANARVIDEORANGE = false,
        .HAVE_KCVPIXELFORMATTYPE_444YPCBCR8BIPLANARVIDEORANGE = false,
        .HAVE_KCVPIXELFORMATTYPE_444YPCBCR10BIPLANARVIDEORANGE = false,
        .HAVE_KCVPIXELFORMATTYPE_444YPCBCR16BIPLANARVIDEORANGE = false,
        .HAVE_KCVPIXELFORMATTYPE_422YPCBCR8_YUVS = false,
        .HAVE_KCVIMAGEBUFFERTRANSFERFUNCTION_SMPTE_ST_2084_PQ = false,
        .HAVE_KCVIMAGEBUFFERTRANSFERFUNCTION_ITU_R_2100_HLG = false,
        .HAVE_KCVIMAGEBUFFERTRANSFERFUNCTION_LINEAR = false,
        .HAVE_KCVIMAGEBUFFERYCBCRMATRIX_ITU_R_2020 = false,
        .HAVE_KCVIMAGEBUFFERCOLORPRIMARIES_ITU_R_2020 = false,
        .HAVE_KCVIMAGEBUFFERTRANSFERFUNCTION_ITU_R_2020 = false,
        .HAVE_KCVIMAGEBUFFERTRANSFERFUNCTION_SMPTE_ST_428_1 = false,
        .HAVE_KVTQPMODULATIONLEVEL_DEFAULT = false,
        .HAVE_SECPKGCONTEXT_KEYINGMATERIALINFO = false,
        .HAVE_SOCKLEN_T = true,
        .HAVE_STRUCT_ADDRINFO = true,
        .HAVE_STRUCT_GROUP_SOURCE_REQ = true,
        .HAVE_STRUCT_IP_MREQ_SOURCE = true,
        .HAVE_STRUCT_IPV6_MREQ = true,
        .HAVE_STRUCT_MSGHDR_MSG_FLAGS = true,
        .HAVE_STRUCT_POLLFD = true,
        .HAVE_STRUCT_RUSAGE_RU_MAXRSS = true,
        .HAVE_STRUCT_SCTP_EVENT_SUBSCRIBE = false,
        .HAVE_STRUCT_SOCKADDR_IN6 = true,
        .HAVE_STRUCT_SOCKADDR_SA_LEN = darwin,
        .HAVE_STRUCT_SOCKADDR_STORAGE = true,
        .HAVE_STRUCT_STAT_ST_MTIM_TV_NSEC = linux,
        .HAVE_STRUCT_V4L2_FRMIVALENUM_DISCRETE = linux,
        .HAVE_STRUCT_MFXCONFIGINTERFACE = false,
        .HAVE_GZIP = true,
        .HAVE_IOCTL_POSIX = false,
        .HAVE_LIBDRM_GETFB2 = true,
        .HAVE_MAKEINFO = false,
        .HAVE_MAKEINFO_HTML = false,
        .HAVE_OPENCL_D3D11 = false,
        .HAVE_OPENCL_DRM_ARM = false,
        .HAVE_OPENCL_DRM_BEIGNET = false,
        .HAVE_OPENCL_DXVA2 = false,
        .HAVE_OPENCL_VAAPI_BEIGNET = false,
        .HAVE_OPENCL_VAAPI_INTEL_MEDIA = false,
        .HAVE_OPENCL_VIDEOTOOLBOX = false,
        .HAVE_PERL = true,
        .HAVE_POD2MAN = true,
        .HAVE_TEXI2HTML = false,
        .HAVE_XMLLINT = true,
        .HAVE_ZLIB_GZIP = true,
        .HAVE_OPENVINO2 = false,
        .CONFIG_ICONV = true,
        .CONFIG_LINUX_PERF = linux and (a64 or t.cpu.arch.isArm()),
        .CONFIG_NEON_CLOBBER_TEST = false,
        .CONFIG_XMM_CLOBBER_TEST = false,
        .const_nan = true,
        .cxx17 = true,
        .libdl = !windows,
        .libm = !msvc,
        .linux_fb_h = linux,
        .linux_videodev2_h = linux,
        .stdatomic = true,
        // No glslc or shaderc, so no Vulkan shaders are compiled.
        .spirv_compiler = false,
        .spirv_library = false,
    };
    s.setFacts(common);
}

pub fn add(c: Ctx, s: *const resolve.State, o: Options) Headers {
    const b = c.b;
    const t = c.target.result;
    const windows = t.os.tag == .windows;
    const darwin = t.os.tag.isDarwin();

    const config_asm = b.addConfigHeader(.{ .style = .nasm, .include_path = "config.asm" }, .{});
    s.define(config_asm);

    var configuration: std.ArrayList(u8) = .empty;
    configuration.appendSlice(b.allocator, base_configuration) catch @panic("OOM");
    if (o.gpl) configuration.appendSlice(b.allocator, " --enable-gpl") catch @panic("OOM");
    if (o.version3) configuration.appendSlice(b.allocator, " --enable-version3") catch @panic("OOM");
    for (o.libraries) |lib| {
        const flag = b.fmt(" --enable-{s}", .{lib});
        std.mem.replaceScalar(u8, flag, '_', '-');
        configuration.appendSlice(b.allocator, flag) catch @panic("OOM");
    }

    const config_h = b.addConfigHeader(.{
        .include_path = "config.h",
        .include_guard = "FFMPEG_CONFIG_H",
    }, .{
        .FFMPEG_CONFIGURATION = configuration.items,
        .FFMPEG_LICENSE = if (o.gpl)
            (if (o.version3) "GPL version 3 or later" else "GPL version 2 or later")
        else
            (if (o.version3) "LGPL version 3 or later" else "LGPL version 2.1 or later"),
        .CONFIG_THIS_YEAR = 2026,
        .FFMPEG_DATADIR = "/ffoxide-ffmpeg/share/ffmpeg",
        .AVCONV_DATADIR = "/ffoxide-ffmpeg/share/ffmpeg",
        .CC_IDENT = "zig cc",
        .EXTERN_PREFIX = if (darwin or (windows and t.cpu.arch == .x86)) "_" else "",
    });
    config_h.addIdent("OS_NAME", osName(t.os.tag));
    if (darwin or (windows and t.cpu.arch == .x86)) {
        config_h.addIdent("EXTERN_ASM", "_");
    } else {
        config_h.addValues(.{ .EXTERN_ASM = {} });
    }
    if (t.cpu.arch.isAARCH64()) {
        // configure's highest `.arch` level zig's assembler accepts, plus clang's "+fp" workaround.
        config_h.addIdent("AS_ARCH_LEVEL", "armv8.6-a+fp");
    }
    config_h.addValues(.{
        .BUILDSUF = "",
        .SLIBSUF = t.os.tag.dynamicLibSuffix(),
        .SWS_MAX_FILTER_SIZE = 256,
    });
    s.define(config_h);

    const avconfig_h = b.addConfigHeader(.{
        .include_path = "libavutil/avconfig.h",
        .include_guard = "AVUTIL_AVCONFIG_H",
    }, .{
        .AV_HAVE_BIGENDIAN = s.enabled("bigendian"),
        .AV_HAVE_FAST_UNALIGNED = s.enabled("fast_unaligned"),
    });

    return .{ .config_h = config_h, .config_asm = config_asm, .avconfig_h = avconfig_h };
}

/// The base configure options tools/ffmpeg_gen.py resolves from, without paths or tool overrides.
const base_configuration = "--enable-static --disable-shared --enable-pic --disable-programs --disable-doc " ++
    "--disable-debug --disable-autodetect --enable-runtime-cpudetect --enable-network --enable-pixelutils";

fn osName(tag: std.Target.Os.Tag) []const u8 {
    return switch (tag) {
        .windows => "win64",
        .macos, .ios, .tvos, .watchos, .visionos => "darwin",
        else => "linux",
    };
}

fn fastUnalignedLoads(t: std.Target) bool {
    return switch (t.cpu.arch) {
        .x86_64, .aarch64 => true,
        else => false,
    };
}

fn have_arm_feat(t: std.Target, feat: std.Target.arm.Feature) bool {
    return switch (t.cpu.arch) {
        .arm, .armeb => std.Target.arm.featureSetHas(t.cpu.features, feat),
        else => false,
    };
}

fn have_aarch64_feat(t: std.Target, feat: std.Target.aarch64.Feature) bool {
    return switch (t.cpu.arch) {
        .aarch64, .aarch64_be => std.Target.aarch64.featureSetHas(t.cpu.features, feat),
        else => false,
    };
}

fn have_ppc_feat(t: std.Target, feat: std.Target.powerpc.Feature) bool {
    return switch (t.cpu.arch) {
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => std.Target.powerpc.featureSetHas(t.cpu.features, feat),
        else => false,
    };
}

fn have_wasm_feat(t: std.Target, feat: std.Target.wasm.Feature) bool {
    return switch (t.cpu.arch) {
        .wasm32, .wasm64 => std.Target.wasm.featureSetHas(t.cpu.features, feat),
        else => false,
    };
}

fn have_mips_feat(t: std.Target, feat: std.Target.mips.Feature) bool {
    return switch (t.cpu.arch) {
        .mips, .mipsel, .mips64, .mips64el => std.Target.mips.featureSetHas(t.cpu.features, feat),
        else => false,
    };
}

fn missing_mips_feat(t: std.Target, feat: std.Target.mips.Feature) bool {
    return switch (t.cpu.arch) {
        .mips, .mipsel, .mips64, .mips64el => !std.Target.mips.featureSetHas(t.cpu.features, feat),
        else => false,
    };
}
