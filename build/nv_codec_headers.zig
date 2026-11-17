//! NVIDIA's ffnvcodec headers, installed under `ffnvcodec/` like `make install`. The driver
//! loads the CUDA and NVENC runtimes at run time, so there is no archive.
const Ctx = @import("Ctx.zig");
const Nasm = @import("Nasm.zig");
const Meta = @import("Meta.zig");

pub const meta: Meta = .{
    .name = "nv_codec_headers",
    .version = "n12.1.14.0",
    .ffmpeg = &.{ "ffnvcodec", "nvenc", "nvdec", "cuvid", "cuda_llvm" },
    .ffmpeg_probes = &.{ "cuda", "NV_ENC_PIC_PARAMS_AV1", "CUVIDAV1PICPARAMS" },
    .supports = Meta.support.linuxOrWindows,
};

pub fn build(c: Ctx, _: Nasm) ?Ctx.Output {
    return c.headerOnly(&.{.{ "ffnvcodec", c.upstream("nv_codec_headers").path("include/ffnvcodec") }});
}
