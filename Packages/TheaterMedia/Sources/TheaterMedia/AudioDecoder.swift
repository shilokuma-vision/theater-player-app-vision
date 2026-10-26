//
//  AudioDecoder.swift
//  TheaterMedia
//
//  音声のデコード（自分のスレッドで回す）。デコード → 48 kHz の float → 映画館の音響処理 → スピーカーごとの信号を輪のバッファへ。
//  音の時刻と輪のバッファの位置の対応（AudioTimeline）を持ち、それが再生の時計になる（MediaPlayer.currentTime）。
//

import CFFmpeg
import CinemaAudio
import Foundation
import Synchronization

/// 輪のバッファの位置と、メディアの時刻の対応
final class AudioTimeline: @unchecked Sendable {
    struct Base {
        /// この区間の最初のサンプルを書いた輪のバッファの位置
        let ringIndex: Int
        /// そのサンプルのメディアの時刻（秒）
        let time: Double
        /// 1 サンプルで進むメディアの時刻（再生の速さ ÷ 48 kHz）
        let secondsPerFrame: Double
    }

    private let lock = NSLock()
    private var base: Base?

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        base = nil
    }

    func set(_ newBase: Base) {
        lock.lock()
        defer { lock.unlock() }
        base = newBase
    }

    var current: Base? {
        lock.lock()
        defer { lock.unlock() }
        return base
    }

    /// 輪のバッファの位置（出力のサンプル）のメディアの時刻。音響処理の遅れの分を引く
    func time(atRingIndex index: Int) -> Double? {
        guard let base = current else {
            return nil
        }
        let frames = index - base.ringIndex - CinemaProcessor.latencyFrames
        return base.time + Double(frames) * base.secondsPerFrame
    }
}

final class AudioDecoder: @unchecked Sendable {
    let streamIndex: Int
    let queue = PacketQueue()
    private let codec: UnsafeMutablePointer<AVCodecContext>
    private let frame: UnsafeMutablePointer<AVFrame>
    private let timeBase: AVRational
    private let startTime: Double
    private let resampler = AudioResampler()
    private let processor: CinemaProcessor
    private let ring: SpeakerFeedRing
    private let timeline: AudioTimeline
    private let control: PlaybackControl
    private var decoderSerial = -1
    /// この区間で書いた入力のサンプルの数
    private var writtenInSegment = 0
    private let feeds: PlanarFeeds
    private var tempo: AudioTempo?
    /// 再生の速さ（1 以外なら atempo を通す）
    var playbackRate: Double = 1

    init(
        stream: UnsafeMutablePointer<AVStream>,
        index: Int,
        startTime: Double,
        control: PlaybackControl,
        processor: CinemaProcessor,
        ring: SpeakerFeedRing,
        timeline: AudioTimeline
    ) throws {
        guard let decoder = avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id),
              let context = avcodec_alloc_context3(decoder), let frame = av_frame_alloc() else {
            throw MediaError("この音声の形式には対応していません")
        }
        codec = context
        self.frame = frame
        try check(avcodec_parameters_to_context(context, stream.pointee.codecpar), "音声の設定")
        context.pointee.pkt_timebase = stream.pointee.time_base
        try check(avcodec_open2(context, decoder, nil), "音声のデコーダーを開けません")
        streamIndex = index
        timeBase = stream.pointee.time_base
        self.startTime = startTime
        self.control = control
        self.processor = processor
        self.ring = ring
        self.timeline = timeline
        feeds = PlanarFeeds(count: processor.feeds.count, frames: 8_192)
    }

    deinit {
        var context: UnsafeMutablePointer<AVCodecContext>? = codec
        avcodec_free_context(&context)
        var pointer: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&pointer)
    }

    /// このデコーダーを止める（トラックを替えるとき）
    private let active = Atomic<Bool>(true)

    func deactivate() {
        active.store(false, ordering: .releasing)
        queue.abort()
    }

    func run() {
        while !control.isStopped, active.load(ordering: .acquiring) {
            guard let item = queue.take() else {
                continue
            }
            switch item {
            case let .packet(packet, serial):
                var pointer: UnsafeMutablePointer<AVPacket>? = packet
                defer { av_packet_free(&pointer) }
                guard serial == control.serial else {
                    continue
                }
                prepare(serial: serial)
                if avcodec_send_packet(codec, packet) >= 0 {
                    receiveFrames(serial: serial)
                }
            case let .endOfStream(serial):
                guard serial == control.serial else {
                    continue
                }
                prepare(serial: serial)
                avcodec_send_packet(codec, nil)
                receiveFrames(serial: serial)
                flushProcessorTail(serial: serial)
                avcodec_flush_buffers(codec)
                decoderSerial = -1
                control.markEnded(.audio, serial: serial)
            }
        }
    }

    private func prepare(serial: Int) {
        guard serial != decoderSerial else {
            return
        }
        if decoderSerial >= 0 {
            avcodec_flush_buffers(codec)
        }
        decoderSerial = serial
        processor.reset()
        ring.flush()
        timeline.reset()
        writtenInSegment = 0
    }

    private func receiveFrames(serial: Int) {
        while serial == control.serial, avcodec_receive_frame(codec, frame) >= 0 {
            defer { av_frame_unref(frame) }
            handle(serial: serial)
        }
    }

    private func handle(serial: Int) {
        let rate = Double(frame.pointee.sample_rate)
        guard rate > 0 else {
            return
        }
        let stamp = frame.pointee.best_effort_timestamp != tp_no_pts() ? frame.pointee.best_effort_timestamp : frame.pointee.pts
        let time = stamp != tp_no_pts() ? Double(stamp) * av_q2d(timeBase) - startTime : nil
        let duration = Double(frame.pointee.nb_samples) / rate
        // 正確なシーク：シーク先より前の音は捨て、またぐフレームは頭を切る
        var skip = 0
        if let target = control.seekTarget(for: serial), let time {
            if time + duration <= target {
                return
            }
            if timeline.current == nil, time < target {
                skip = Int((target - time) * Double(AudioResampler.sampleRate))
            }
        }
        let speed = playbackRate
        guard abs(speed - 1) > 0.001 else {
            convert(frame, skip: skip, time: time, serial: serial)
            return
        }
        // 速さを変える：atempo を通してから変換する（シークの頭の切り落としも速さで割る）
        if tempo == nil || !(tempo?.matches(frame, tempo: speed) ?? false) {
            tempo = try? AudioTempo(like: frame, tempo: speed)
        }
        guard let tempo else {
            convert(frame, skip: skip, time: time, serial: serial)
            return
        }
        var remainingSkip = Int(Double(skip) / speed)
        tempo.process(frame) { output in
            convert(output, skip: remainingSkip, time: time, serial: serial)
            remainingSkip = max(0, remainingSkip - Int(output.pointee.nb_samples))
        }
    }

    private func convert(_ source: UnsafeMutablePointer<AVFrame>, skip: Int, time: Double?, serial: Int) {
        do {
            try resampler.convert(source) { channels, count, changed in
                if changed {
                    processor.configure(input: resampler.layout)
                }
                write(channels, count: count, skip: min(skip, count), time: time, serial: serial)
            }
        } catch {
            return
        }
    }

    /// 音響処理に通して輪のバッファへ書く。区間の始まりなら、時刻の対応を決める
    private func write(_ channels: [UnsafePointer<Float>], count: Int, skip: Int, time: Double?, serial: Int) {
        let frames = count - skip
        guard frames > 0 else {
            return
        }
        let sampleRate = Double(AudioResampler.sampleRate)
        if timeline.current == nil {
            let start = (time ?? 0) + Double(skip) / sampleRate
            timeline.set(AudioTimeline.Base(ringIndex: ring.writtenFrames, time: start, secondsPerFrame: playbackRate / sampleRate))
            writtenInSegment = 0
        }
        var offset = skip
        while offset < count, serial == control.serial, !control.isStopped {
            let chunk = min(count - offset, feeds.frames)
            processor.process(input: channels.map { $0 + offset }, frames: chunk, output: feeds.pointers)
            guard push(frames: chunk, serial: serial) else {
                return
            }
            offset += chunk
            writtenInSegment += chunk
        }
    }

    /// 輪のバッファに書く。空きが無ければ待つ（シーク・閉じたら false）
    private func push(frames: Int, serial: Int) -> Bool {
        var done = 0
        while done < frames {
            if control.isStopped || serial != control.serial {
                return false
            }
            let written = ring.write(feeds.pointers.map { UnsafePointer($0 + done) }, frames: frames - done)
            done += written
            if written == 0 {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        return true
    }

    /// ファイルの終わり：音響処理の中に残った分（遅れの分）を、無音を入れて押し出す
    private func flushProcessorTail(serial: Int) {
        let silence = PlanarFeeds(count: max(resampler.channelCount, 1), frames: CinemaProcessor.latencyFrames)
        processor.process(input: silence.pointers.map { UnsafePointer($0) }, frames: CinemaProcessor.latencyFrames, output: feeds.pointers)
        _ = push(frames: CinemaProcessor.latencyFrames, serial: serial)
    }
}

/// チャンネルごとの float の領域
final class PlanarFeeds: @unchecked Sendable {
    let pointers: [UnsafeMutablePointer<Float>]
    let frames: Int

    init(count: Int, frames: Int) {
        self.frames = frames
        pointers = (0..<count).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(repeating: 0, count: frames)
            return pointer
        }
    }

    deinit {
        pointers.forEach { $0.deallocate() }
    }
}
