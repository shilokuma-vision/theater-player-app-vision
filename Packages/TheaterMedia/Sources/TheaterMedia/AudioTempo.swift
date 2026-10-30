//
//  AudioTempo.swift
//  TheaterMedia
//
//  再生の速さを変えたときの音（FFmpeg の atempo。音の高さを変えずに速さだけ変える）。
//

import CFFmpeg
import Foundation

final class AudioTempo {
    let tempo: Double
    private let format: Int32
    private let sampleRate: Int32
    private let channels: Int32
    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var source: UnsafeMutablePointer<AVFilterContext>?
    private var sink: UnsafeMutablePointer<AVFilterContext>?
    private let output: UnsafeMutablePointer<AVFrame>
    /// 最初に入れた音のメディアの時刻と、出した数（atempo の中にたまる分で入力の時刻とずれるので、出した数から時刻を決める）
    private var origin: Double?
    private var producedFrames = 0

    init(like frame: UnsafeMutablePointer<AVFrame>, tempo: Double) throws {
        guard let output = av_frame_alloc(), let graph = avfilter_graph_alloc() else {
            throw MediaError("速さを変える準備ができません")
        }
        self.output = output
        self.graph = graph
        self.tempo = tempo
        format = frame.pointee.format
        sampleRate = frame.pointee.sample_rate
        channels = frame.pointee.ch_layout.nb_channels
        var name = [CChar](repeating: 0, count: 64)
        av_channel_layout_describe(&frame.pointee.ch_layout, &name, name.count)
        let layout = String(bytes: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
        let sampleFormat = av_get_sample_fmt_name(AVSampleFormat(rawValue: format)).map { String(cString: $0) } ?? "fltp"
        let arguments = "time_base=1/\(sampleRate):sample_rate=\(sampleRate):sample_fmt=\(sampleFormat):channel_layout=\(layout)"
        try check(avfilter_graph_create_filter(&source, avfilter_get_by_name("abuffer"), "in", arguments, nil, graph), "音の入口")
        try check(avfilter_graph_create_filter(&sink, avfilter_get_by_name("abuffersink"), "out", nil, nil, graph), "音の出口")
        var filter: UnsafeMutablePointer<AVFilterContext>?
        try check(avfilter_graph_create_filter(&filter, avfilter_get_by_name("atempo"), "tempo", "tempo=\(tempo)", nil, graph), "atempo")
        try check(avfilter_link(source, 0, filter, 0), "つなぐ")
        try check(avfilter_link(filter, 0, sink, 0), "つなぐ")
        try check(avfilter_graph_config(graph, nil), "準備")
    }

    deinit {
        avfilter_graph_free(&graph)
        var frame: UnsafeMutablePointer<AVFrame>? = output
        av_frame_free(&frame)
    }

    /// 同じ形式の音声か（違えば作り直す）
    func matches(_ frame: UnsafeMutablePointer<AVFrame>, tempo: Double) -> Bool {
        self.tempo == tempo && format == frame.pointee.format && sampleRate == frame.pointee.sample_rate
            && channels == frame.pointee.ch_layout.nb_channels
    }

    /// frame（メディアの時刻 time）を入れ、出てきたフレームとその最初のサンプルのメディアの時刻を body に渡す
    func process(_ frame: UnsafeMutablePointer<AVFrame>, time: Double?, _ body: (UnsafeMutablePointer<AVFrame>, Double?) -> Void) {
        if origin == nil, let time {
            origin = time - Double(producedFrames) * tempo / Double(sampleRate)
        }
        guard av_buffersrc_add_frame_flags(source, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF)) >= 0 else {
            return
        }
        while av_buffersink_get_frame(sink, output) >= 0 {
            // 出した 1 サンプルは、入力の tempo サンプル分のメディアの時刻に当たる
            body(output, origin.map { $0 + Double(producedFrames) * tempo / Double(sampleRate) })
            producedFrames += Int(output.pointee.nb_samples)
            av_frame_unref(output)
        }
    }
}
