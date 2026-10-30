//
//  shim.c
//  CFFmpeg
//

#include "CFFmpeg.h"

#include <VideoToolbox/VideoToolbox.h>
#include <stdatomic.h>
#include <stdlib.h>

void tp_error_string(int code, char *buffer, size_t size) {
    av_strerror(code, buffer, size);
}

struct TPInterrupt {
    atomic_int requested;
};

TPInterrupt *tp_interrupt_create(void) {
    TPInterrupt *interrupt = malloc(sizeof(TPInterrupt));
    atomic_init(&interrupt->requested, 0);
    return interrupt;
}

void tp_interrupt_destroy(TPInterrupt *interrupt) {
    free(interrupt);
}

void tp_interrupt_request(TPInterrupt *interrupt) {
    atomic_store(&interrupt->requested, 1);
}

static int tp_interrupt_callback(void *opaque) {
    TPInterrupt *interrupt = opaque;
    return interrupt != NULL && atomic_load(&interrupt->requested) != 0;
}

void tp_set_interrupt(AVFormatContext *context, TPInterrupt *interrupt) {
    context->interrupt_callback.callback = tp_interrupt_callback;
    context->interrupt_callback.opaque = interrupt;
}

/// VideoToolbox（ハードウェア）で解ける形式か。software はソフトウェアで解くときの画素の形式。
/// FFmpeg は、VideoToolbox が解けない形式（H.264 の 10 bit・4:2:2・4:4:4 など）でも候補に出すので、ここで選り分ける。
/// 選ばなかった形式は、FFmpeg のソフトウェアのデコーダーで解く
static int tp_videotoolbox_can_decode(const AVCodecContext *context, enum AVPixelFormat software) {
    const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(software);
    if (descriptor == NULL) {
        return 0;
    }
    int depth = descriptor->comp[0].depth;
    int is420 = descriptor->log2_chroma_w == 1 && descriptor->log2_chroma_h == 1;
    switch (context->codec_id) {
    case AV_CODEC_ID_H264:
        // VideoToolbox の H.264 は 8 bit の 4:2:0 だけ
        return is420 && depth == 8 && VTIsHardwareDecodeSupported(kCMVideoCodecType_H264);
    case AV_CODEC_ID_HEVC:
        return is420 && depth <= 10 && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    case AV_CODEC_ID_VP9:
        return is420 && depth <= 10 && VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9);
    case AV_CODEC_ID_AV1:
        return is420 && depth <= 10 && VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);
    case AV_CODEC_ID_PRORES:
        return 1;
    default:
        // MPEG-1・MPEG-2・MPEG-4・H.263 などは、ソフトウェアで十分に速い
        return 0;
    }
}

static enum AVPixelFormat tp_get_format(AVCodecContext *context, const enum AVPixelFormat *formats) {
    int offersVideoToolbox = 0;
    enum AVPixelFormat software = AV_PIX_FMT_NONE;
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++) {
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX) {
            offersVideoToolbox = 1;
            continue;
        }
        const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(*format);
        if (software == AV_PIX_FMT_NONE && descriptor != NULL && !(descriptor->flags & AV_PIX_FMT_FLAG_HWACCEL)) {
            software = *format;
        }
    }
    if (offersVideoToolbox && tp_videotoolbox_can_decode(context, software)) {
        return AV_PIX_FMT_VIDEOTOOLBOX;
    }
    // VideoToolbox を使わない：ソフトウェアのデコードの形式
    return software != AV_PIX_FMT_NONE ? software : formats[0];
}

/// 今のデコードで VideoToolbox を使っているか（get_format で選んだ後）
int tp_uses_videotoolbox(const AVCodecContext *context) {
    return context->hw_device_ctx != NULL && context->pix_fmt == AV_PIX_FMT_VIDEOTOOLBOX;
}

void tp_use_videotoolbox(AVCodecContext *context) {
    context->get_format = tp_get_format;
}

uint8_t *tp_frame_data(const AVFrame *frame, int plane) {
    return plane >= 0 && plane < AV_NUM_DATA_POINTERS ? frame->data[plane] : NULL;
}

int tp_frame_linesize(const AVFrame *frame, int plane) {
    return plane >= 0 && plane < AV_NUM_DATA_POINTERS ? frame->linesize[plane] : 0;
}

CVPixelBufferRef tp_frame_pixel_buffer(const AVFrame *frame) {
    return frame->format == AV_PIX_FMT_VIDEOTOOLBOX ? (CVPixelBufferRef)frame->data[3] : NULL;
}

uint8_t *tp_subtitle_rect_data(const AVSubtitleRect *rect, int plane) {
    return plane >= 0 && plane < 4 ? rect->data[plane] : NULL;
}

int tp_subtitle_rect_linesize(const AVSubtitleRect *rect, int plane) {
    return plane >= 0 && plane < 4 ? rect->linesize[plane] : 0;
}

void tp_quiet_logs(void) {
    av_log_set_level(AV_LOG_WARNING);
}
