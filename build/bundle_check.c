#include <stdio.h>

#include <libavcodec/avcodec.h>
#include <libavdevice/avdevice.h>
#include <libavfilter/avfilter.h>
#include <libavformat/avformat.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

static int count(const void *(*next)(void **)) {
    void *it = NULL;
    int n = 0;
    while (next(&it)) n++;
    return n;
}

static const void *codec(void **it) { return av_codec_iterate(it); }
static const void *demuxer(void **it) { return av_demuxer_iterate(it); }
static const void *muxer(void **it) { return av_muxer_iterate(it); }

int main(void) {
    int codecs = count(codec), demuxers = count(demuxer), muxers = count(muxer);
    int filters = 0;
    void *it = NULL;
    while (av_filter_iterate(&it)) filters++;

    avdevice_register_all();
    avformat_network_init();

    SwrContext *swr = swr_alloc();
    struct SwsContext *sws = sws_getContext(64, 64, AV_PIX_FMT_YUV420P, 64, 64, AV_PIX_FMT_RGB24, SWS_BILINEAR, NULL, NULL, NULL);
    int ok = codecs && demuxers && muxers && filters && swr && sws;
    swr_free(&swr);
    sws_freeContext(sws);
    avformat_network_deinit();

    printf("%d codecs, %d demuxers, %d muxers, %d filters\n", codecs, demuxers, muxers, filters);
    return ok ? 0 : 1;
}
