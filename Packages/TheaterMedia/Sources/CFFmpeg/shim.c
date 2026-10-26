//
//  shim.c
//  CFFmpeg
//

#include "CFFmpeg.h"

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

static enum AVPixelFormat tp_get_format(AVCodecContext *context, const enum AVPixelFormat *formats) {
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++) {
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX) {
            return *format;
        }
    }
    // VideoToolbox を使えない（対応していない形式）：ソフトウェアのデコードの最初の形式
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++) {
        const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(*format);
        if (descriptor != NULL && !(descriptor->flags & AV_PIX_FMT_FLAG_HWACCEL)) {
            return *format;
        }
    }
    return formats[0];
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
