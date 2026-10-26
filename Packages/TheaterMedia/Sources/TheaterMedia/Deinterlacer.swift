//
//  Deinterlacer.swift
//  TheaterMedia
//
//  インターレースの映像（DVD・放送の録画など）を、FFmpeg の bwdif でプログレッシブにする。
//  1 フィールドを 1 枚にする（50i → 50p。VLC の「Yadif (2x)」と同じ考え方で、動きがなめらか）。
//

import CFFmpeg
import Foundation

final class Deinterlacer {
    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var source: UnsafeMutablePointer<AVFilterContext>?
    private var sink: UnsafeMutablePointer<AVFilterContext>?
    private let output: UnsafeMutablePointer<AVFrame>
    /// 出力のフレームの時刻の単位
    private(set) var timeBase = AVRational(num: 1, den: 1)

    init(width: Int32, height: Int32, format: Int32, timeBase: AVRational, aspect: AVRational) throws {
        guard let frame = av_frame_alloc() else {
            throw MediaError("インターレースの解除を準備できません")
        }
        output = frame
        guard let graph = avfilter_graph_alloc() else {
            throw MediaError("インターレースの解除を準備できません")
        }
        self.graph = graph
        let aspectNum = max(aspect.num, 1)
        let aspectDen = max(aspect.den, 1)
        let arguments = "video_size=\(width)x\(height):pix_fmt=\(format):time_base=\(timeBase.num)/\(timeBase.den):"
            + "pixel_aspect=\(aspectNum)/\(aspectDen)"
        try check(avfilter_graph_create_filter(&source, avfilter_get_by_name("buffer"), "in", arguments, nil, graph), "映像の入口")
        try check(avfilter_graph_create_filter(&sink, avfilter_get_by_name("buffersink"), "out", nil, nil, graph), "映像の出口")
        var deinterlace: UnsafeMutablePointer<AVFilterContext>?
        try check(
            avfilter_graph_create_filter(
                &deinterlace,
                avfilter_get_by_name("bwdif"),
                "deinterlace",
                "mode=send_field:parity=auto:deint=interlaced",
                nil,
                graph
            ),
            "bwdif"
        )
        try check(avfilter_link(source, 0, deinterlace, 0), "つなぐ")
        try check(avfilter_link(deinterlace, 0, sink, 0), "つなぐ")
        try check(avfilter_graph_config(graph, nil), "準備")
        self.timeBase = av_buffersink_get_time_base(sink)
    }

    deinit {
        avfilter_graph_free(&graph)
        var frame: UnsafeMutablePointer<AVFrame>? = output
        av_frame_free(&frame)
    }

    /// frame を入れ、出てきたフレームを body に渡す（1 枚から 0〜2 枚）。body の中で frame を使い終える
    func process(_ frame: UnsafeMutablePointer<AVFrame>, _ body: (UnsafeMutablePointer<AVFrame>) -> Void) {
        guard av_buffersrc_add_frame_flags(source, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF)) >= 0 else {
            return
        }
        while av_buffersink_get_frame(sink, output) >= 0 {
            body(output)
            av_frame_unref(output)
        }
    }
}
