//
//  CFFmpeg.h
//  CFFmpeg
//
//  Swift から FFmpeg を使うための入口。Swift に取り込めないマクロ（AVERROR など）と、
//  C の関数ポインターが要るコールバック（中断・VideoToolbox の選択）をここで包む。
//

#ifndef CFFMPEG_H
#define CFFMPEG_H

#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/display.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/imgutils.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <CoreVideo/CoreVideo.h>

/// AVERROR(EAGAIN)：もっと入力が要る
static inline int tp_error_again(void) { return AVERROR(EAGAIN); }
/// AVERROR_EOF：終わり
static inline int tp_error_eof(void) { return AVERROR_EOF; }
/// AV_NOPTS_VALUE：時刻が無い
static inline int64_t tp_no_pts(void) { return AV_NOPTS_VALUE; }
/// AV_TIME_BASE（1 秒 = 1,000,000）
static inline int tp_time_base(void) { return AV_TIME_BASE; }

/// FFmpeg のエラーの文字列
void tp_error_string(int code, char *buffer, size_t size);

/// 読み込みの中断の印（AVFormatContext の interrupt_callback に渡す）。中身は C の側だけで持つ
typedef struct TPInterrupt TPInterrupt;

TPInterrupt *tp_interrupt_create(void);
void tp_interrupt_destroy(TPInterrupt *interrupt);
/// 中断させる（別のスレッドから呼んでよい）
void tp_interrupt_request(TPInterrupt *interrupt);
void tp_set_interrupt(AVFormatContext *context, TPInterrupt *interrupt);

/// デコーダーの get_format：VideoToolbox で解ける形式なら選ぶ（解けなければソフトウェアの形式）
void tp_use_videotoolbox(AVCodecContext *context);
/// 今のデコードで VideoToolbox を使っているか（get_format で選んだ後）
int tp_uses_videotoolbox(const AVCodecContext *context);

/// フレームの data[i]・linesize[i]（Swift では配列がタプルになるため）
uint8_t *tp_frame_data(const AVFrame *frame, int plane);
int tp_frame_linesize(const AVFrame *frame, int plane);
/// VideoToolbox でデコードしたフレームの CVPixelBuffer（data[3]）。それ以外は NULL
CVPixelBufferRef tp_frame_pixel_buffer(const AVFrame *frame);

/// 字幕の領域の data[i]・linesize[i]
uint8_t *tp_subtitle_rect_data(const AVSubtitleRect *rect, int plane);
int tp_subtitle_rect_linesize(const AVSubtitleRect *rect, int plane);

/// ログを警告以上に絞る
void tp_quiet_logs(void);

#endif /* CFFMPEG_H */
