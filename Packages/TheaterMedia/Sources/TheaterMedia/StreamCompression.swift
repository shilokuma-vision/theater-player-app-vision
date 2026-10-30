//
//  StreamCompression.swift
//  TheaterMedia
//
//  AC-3・E-AC-3 のストリームに入っている音量の幅の圧縮（DRC）を、「音量の幅」の設定に合わせてかける。
//  FFmpeg の ac3・eac3 のデコーダーは、何も渡さないとストリームの DRC をそのままかける（drc_scale の既定が 1）。
//  ほかの形式（AAC・DTS・TrueHD など）は、FFmpeg のデコーダーがストリームの DRC をかけないので、何もしない。
//

import CFFmpeg
import CinemaAudio

enum StreamCompression {
    /// ストリームの DRC をかけるデコーダーの形式（ac3・eac3 のデコーダーの drc_scale が効く）
    static func applies(to codecID: AVCodecID) -> Bool {
        codecID == AV_CODEC_ID_AC3 || codecID == AV_CODEC_ID_EAC3
    }

    /// ストリームの DRC をかける割合（drc_scale。0 でかけない、1 でそのまま）
    /// - 映画館：かけない（ミックスのままの幅）
    /// - 標準：かけない。CinemaAudio のコンプレッサー（2:1）だけで少し抑える（重ねると、大きな音を 2 回縮めて「少し」でなくなる）
    /// - 夜：そのまま（line モード）。CinemaAudio のコンプレッサーと重ねて、いちばん狭くする。
    ///   heavy_compr（RF モード）は使わない。RF モードの値はデコーダーが 11 dB 上げる前提で作られていて、FFmpeg は上げないので、縮めすぎる
    static func scale(for range: CinemaAudioSettings.DynamicRange) -> Double {
        switch range {
        case .cinema, .standard:
            0
        case .night:
            1
        }
    }

    /// デコーダーを開くときのオプション（avcodec_open2 に渡す）に加える。options は呼んだ側が av_dict_free で解放する
    static func addOptions(for range: CinemaAudioSettings.DynamicRange, to options: inout OpaquePointer?) {
        av_dict_set(&options, "drc_scale", String(scale(for: range)), 0)
    }

    /// 開いたデコーダーの DRC を変える。デコードのスレッドから、パケットを送る合間に呼ぶ
    /// （drc_scale はブロックごとに DRC の値を読むときに使われるので、開き直さなくても次のパケットから効く）。変えられたら true
    @discardableResult
    static func apply(_ range: CinemaAudioSettings.DynamicRange, to context: UnsafeMutablePointer<AVCodecContext>) -> Bool {
        av_opt_set_double(context, "drc_scale", scale(for: range), AV_OPT_SEARCH_CHILDREN) >= 0
    }

    /// 開いたデコーダーの今の drc_scale（オプションの無いデコーダーは nil）
    static func currentScale(of context: UnsafeMutablePointer<AVCodecContext>) -> Double? {
        var value = 0.0
        guard av_opt_get_double(context, "drc_scale", AV_OPT_SEARCH_CHILDREN, &value) >= 0 else {
            return nil
        }
        return value
    }
}
