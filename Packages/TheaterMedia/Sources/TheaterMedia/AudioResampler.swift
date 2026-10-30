//
//  AudioResampler.swift
//  TheaterMedia
//
//  デコードした音声を、映画館の音響処理の入力（48 kHz・チャンネルごとの float）にする。チャンネルの並びは元のまま
//  （5.1・7.1・7.1.4 などをそのまま映画館の系統へ振り分けるため）。並びの分からない音声は、チャンネル数の標準の並びとみなす。
//

import CFFmpeg
import CinemaAudio
import Foundation

final class AudioResampler {
    private struct InputKey: Equatable {
        var format: Int32
        var rate: Int32
        var channels: Int32
        var mask: UInt64
    }

    static let sampleRate: Int32 = 48_000
    private var context: OpaquePointer?
    private var inputKey: InputKey?
    private(set) var layout: [InputChannel] = []
    private var buffers: [UnsafeMutablePointer<Float>] = []
    private var capacity = 0

    deinit {
        swr_free(&context)
        buffers.forEach { $0.deallocate() }
    }

    var channelCount: Int {
        layout.count
    }

    /// frame を変換する。body にチャンネルごとの float と数を渡す。並びが変わったら layoutChanged が true
    func convert(_ frame: UnsafeMutablePointer<AVFrame>, _ body: ([UnsafePointer<Float>], Int, Bool) -> Void) throws {
        var changed = false
        let key = InputKey(
            format: frame.pointee.format,
            rate: frame.pointee.sample_rate,
            channels: frame.pointee.ch_layout.nb_channels,
            mask: Self.mask(frame)
        )
        if inputKey == nil || inputKey! != key {
            try prepare(frame)
            inputKey = key
            changed = true
        }
        let wanted = Int(swr_get_out_samples(context, frame.pointee.nb_samples))
        reserve(max(wanted, 1))
        let converted = buffers.withUnsafeBufferPointer { pointers -> Int32 in
            pointers.withMemoryRebound(to: UnsafeMutablePointer<UInt8>?.self) { output in
                withExtendedData(frame) { input in
                    swr_convert(context, output.baseAddress, Int32(capacity), input, frame.pointee.nb_samples)
                }
            }
        }
        try check(converted, "音声を変換できません")
        body(buffers.map { UnsafePointer($0) }, Int(converted), changed)
    }

    private static func mask(_ frame: UnsafeMutablePointer<AVFrame>) -> UInt64 {
        frame.pointee.ch_layout.order == AV_CHANNEL_ORDER_NATIVE ? frame.pointee.ch_layout.u.mask : 0
    }

    private func withExtendedData<T>(_ frame: UnsafeMutablePointer<AVFrame>,
                                     _ body: (UnsafeMutablePointer<UnsafePointer<UInt8>?>?) -> T) -> T {
        frame.pointee.extended_data.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: Int(frame.pointee.ch_layout.nb_channels)) {
            body($0)
        }
    }

    private func prepare(_ frame: UnsafeMutablePointer<AVFrame>) throws {
        swr_free(&context)
        var input = AVChannelLayout()
        if frame.pointee.ch_layout.order == AV_CHANNEL_ORDER_UNSPEC {
            av_channel_layout_default(&input, frame.pointee.ch_layout.nb_channels)
        } else {
            try check(av_channel_layout_copy(&input, &frame.pointee.ch_layout), "チャンネルの並び")
        }
        defer { av_channel_layout_uninit(&input) }
        var output = AVChannelLayout()
        try check(av_channel_layout_copy(&output, &input), "チャンネルの並び")
        defer { av_channel_layout_uninit(&output) }
        try check(
            swr_alloc_set_opts2(
                &context,
                &output,
                AV_SAMPLE_FMT_FLTP,
                Self.sampleRate,
                &input,
                AVSampleFormat(rawValue: frame.pointee.format),
                frame.pointee.sample_rate,
                0,
                nil
            ),
            "音声の変換の準備"
        )
        try check(swr_init(context), "音声の変換の準備")
        layout = (0..<Int(output.nb_channels)).map { index in
            AudioChannels.role(av_channel_layout_channel_from_index(&output, UInt32(index)))
        }
        buffers.forEach { $0.deallocate() }
        buffers = []
        capacity = 0
    }

    private func reserve(_ frames: Int) {
        guard frames > capacity || buffers.count != layout.count else {
            return
        }
        buffers.forEach { $0.deallocate() }
        capacity = max(frames, 4_096)
        buffers = layout.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: capacity) }
    }
}

/// FFmpeg のチャンネル（AVChannel）と、映画館の音響処理の入力の役割
enum AudioChannels {
    static let table: [(AVChannel, InputChannel)] = [
        (AV_CHAN_FRONT_LEFT, .frontLeft), (AV_CHAN_FRONT_RIGHT, .frontRight), (AV_CHAN_FRONT_CENTER, .frontCenter),
        (AV_CHAN_LOW_FREQUENCY, .lowFrequency), (AV_CHAN_LOW_FREQUENCY_2, .lowFrequency),
        (AV_CHAN_BACK_LEFT, .backLeft), (AV_CHAN_BACK_RIGHT, .backRight), (AV_CHAN_BACK_CENTER, .backCenter),
        (AV_CHAN_SIDE_LEFT, .sideLeft), (AV_CHAN_SIDE_RIGHT, .sideRight),
        (AV_CHAN_SIDE_SURROUND_LEFT, .sideLeft), (AV_CHAN_SIDE_SURROUND_RIGHT, .sideRight),
        (AV_CHAN_SURROUND_DIRECT_LEFT, .sideLeft), (AV_CHAN_SURROUND_DIRECT_RIGHT, .sideRight),
        (AV_CHAN_FRONT_LEFT_OF_CENTER, .frontLeftOfCenter), (AV_CHAN_FRONT_RIGHT_OF_CENTER, .frontRightOfCenter),
        (AV_CHAN_WIDE_LEFT, .wideLeft), (AV_CHAN_WIDE_RIGHT, .wideRight),
        (AV_CHAN_STEREO_LEFT, .frontLeft), (AV_CHAN_STEREO_RIGHT, .frontRight),
        (AV_CHAN_TOP_FRONT_LEFT, .topFrontLeft), (AV_CHAN_TOP_FRONT_RIGHT, .topFrontRight),
        (AV_CHAN_TOP_FRONT_CENTER, .topFrontCenter), (AV_CHAN_TOP_CENTER, .topCenter),
        (AV_CHAN_TOP_BACK_LEFT, .topBackLeft), (AV_CHAN_TOP_BACK_RIGHT, .topBackRight), (AV_CHAN_TOP_BACK_CENTER, .topBackCenter),
        (AV_CHAN_TOP_SIDE_LEFT, .topSideLeft), (AV_CHAN_TOP_SIDE_RIGHT, .topSideRight),
        (AV_CHAN_TOP_SURROUND_LEFT, .topSideLeft), (AV_CHAN_TOP_SURROUND_RIGHT, .topSideRight),
        (AV_CHAN_BOTTOM_FRONT_LEFT, .frontLeft), (AV_CHAN_BOTTOM_FRONT_RIGHT, .frontRight),
        (AV_CHAN_BOTTOM_FRONT_CENTER, .frontCenter)
    ]

    static func role(_ channel: AVChannel) -> InputChannel {
        table.first { $0.0 == channel }?.1 ?? .unknown
    }
}
