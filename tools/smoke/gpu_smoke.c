/* Link check for the Vulkan, AMF, oneVPL and OpenCL packages. The preprocessor conditions are
 * the ones FFmpeg's configure applies (vulkan, vulkan_1_4, amf, libvpl, opencl). The runtime
 * calls must fail cleanly when no GPU runtime is installed.
 * Build: zig cc ... -I<prefix>/include -I<prefix>/include/vpl gpu_smoke.c libvpl.a libOpenCL.a -lc++ -ldl -lpthread */
#include <stdio.h>

#include <vulkan/vulkan.h>
#if !(defined(VK_VERSION_1_5) || (defined(VK_VERSION_1_4) && VK_HEADER_VERSION >= 317))
#error "vulkan_1_4 condition failed"
#endif

#include <AMF/core/Version.h>
#if !((AMF_VERSION_MAJOR << 48 | AMF_VERSION_MINOR << 32 | AMF_VERSION_RELEASE << 16 | AMF_VERSION_BUILD_NUM) >= 0x0001000400240000)
#error "amf condition failed"
#endif

#include <mfxdispatcher.h>
#include <mfxvideo.h>
#include <vpl/mfxdefs.h>
#include <vpl/mfxvideo.h>
typedef struct mfxConfigInterface mfx_config_interface_check;

#include <CL/cl.h>
#if !defined(CL_VERSION_1_2)
#error "opencl condition failed"
#endif

int main(void)
{
    mfxLoader loader = MFXLoad();
    printf("MFXLoad: %s\n", loader ? "loader created" : "no loader");
    if (loader) {
        mfxConfig cfg = MFXCreateConfig(loader);
        mfxSession session = NULL;
        mfxStatus st = MFXCreateSession(loader, 0, &session);
        printf("MFXCreateConfig: %s, MFXCreateSession: %d (no runtime expected)\n", cfg ? "ok" : "null", (int)st);
        if (session)
            MFXClose(session);
        MFXUnload(loader);
    }

    cl_uint n = 0;
    cl_int rc = clGetPlatformIDs(0, NULL, &n);
    printf("clGetPlatformIDs: rc=%d platforms=%u\n", (int)rc, (unsigned)n);

    printf("VK_HEADER_VERSION=%d AMF=%d.%d.%d MFX_VERSION=%d.%d\n", VK_HEADER_VERSION, AMF_VERSION_MAJOR,
           AMF_VERSION_MINOR, AMF_VERSION_RELEASE, MFX_VERSION_MAJOR, MFX_VERSION_MINOR);
    return 0;
}
