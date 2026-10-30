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
        /// この区間のシークの番号
        let serial: Int
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

    /// 輪のバッファの位置（出力のサンプル）のメディアの時刻。音響処理の遅れの分を引く。番号 serial の区間でなければ nil
    func time(atRingIndex index: Int, serial: Int) -> Double? {
        guard let base = current, base.serial == serial else {
            return nil
        }
        // 区間の最初の音が出るまで（音響処理の遅れの分・前の区間の古い位置）は、区間の始まりの時刻
        let frames = max(index - base.ringIndex - CinemaProcessor.latencyFrames, 0)
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
    /// デコーダーのストリームの DRC を合わせた「音量の幅」（AC-3・E-AC-3 のときだけ。ほかの形式は nil）
    private var compressionRange: CinemaAudioSettings.DynamicRange?
    private let rateBits = Atomic<UInt64>(Double(1).bitPattern)
    /// 音の時刻のずれの許し（超えたら無音で埋める・重なりを捨てる。FFmpeg の aresample の min_hard_comp と同じ）
    private static let driftTolerance = 0.1
    /// これより大きく飛んだら、埋めずに時刻の対応を決め直す（時刻の不連続）
    private static let maxGap = 5.0

    /// 再生の速さ（1 以外なら atempo を通す。操作のスレッドが書き、デコードのスレッドが読む）
    var playbackRate: Double {
        get { Double(bitPattern: rateBits.load(ordering: .relaxed)) }
        set { rateBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

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
        // 先にすべての値を決める（この後で失敗しても deinit が context・frame を解放する）
        codec = context
        self.frame = frame
        streamIndex = index
        timeBase = stream.pointee.time_base
        self.startTime = startTime
        self.control = control
        self.processor = processor
        self.ring = ring
        self.timeline = timeline
        feeds = PlanarFeeds(count: processor.feeds.count, frames: 8_192)
        try check(avcodec_parameters_to_context(context, stream.pointee.codecpar), "音声の設定")
        context.pointee.pkt_timebase = stream.pointee.time_base
        var options: OpaquePointer?
        if StreamCompression.applies(to: decoder.pointee.id) {
            let range = processor.latestSettings.dynamicRange
            StreamCompression.addOptions(for: range, to: &options)
            compressionRange = range
        }
        let opened = avcodec_open2(context, decoder, &options)
        av_dict_free(&options)
        try check(opened, "音声のデコーダーを開けません")
        if let compressionRange {
            logCompression(compressionRange)
        }
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

    /// 番号 serial の区間を続けてよいか（シーク・閉じた・トラックを替えたら false。古いデコーダーが輪のバッファに書かないため）
    private func isCurrent(_ serial: Int) -> Bool {
        serial == control.serial && !control.isStopped && active.load(ordering: .acquiring)
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
                followDynamicRange()
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
        // atempo の中にたまった前の位置の音を捨てる
        tempo = nil
        writtenInSegment = 0
    }

    /// 「音量の幅」が変わっていたら、ストリームの DRC を合わせる（デコードのスレッドで、パケットを送る前に。
    /// デコーダーを開き直さないので、途中の音が途切れない）
    func followDynamicRange() {
        guard let current = compressionRange else {
            return
        }
        let range = processor.latestSettings.dynamicRange
        guard range != current, StreamCompression.apply(range, to: codec) else {
            return
        }
        compressionRange = range
        logCompression(range)
    }

    private func logCompression(_ range: CinemaAudioSettings.DynamicRange) {
        Diagnostics.log("audio drc_scale=\(StreamCompression.scale(for: range)) dynamicRange=\(range)")
    }

    /// デコーダーの今の drc_scale（AC-3・E-AC-3 でなければ nil）
    var streamCompressionScale: Double? {
        compressionRange == nil ? nil : StreamCompression.currentScale(of: codec)
    }

    private func receiveFrames(serial: Int) {
        while isCurrent(serial), avcodec_receive_frame(codec, frame) >= 0 {
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
        // 正確なシーク：シーク先より前の音は捨てる（またぐフレームの頭は、書くときに切る）
        if let target = control.seekTarget(for: serial), let time, time + duration <= target {
            return
        }
        let speed = playbackRate
        guard abs(speed - 1) > 0.001 else {
            convert(frame, time: time, speed: 1, serial: serial)
            return
        }
        // 速さを変える：atempo を通してから変換する。出てきた音の時刻は atempo の側で数える
        if tempo == nil || !(tempo?.matches(frame, tempo: speed) ?? false) {
            tempo = try? AudioTempo(like: frame, tempo: speed)
        }
        guard let tempo else {
            convert(frame, time: time, speed: 1, serial: serial)
            return
        }
        tempo.process(frame, time: time) { output, outputTime in
            convert(output, time: outputTime, speed: speed, serial: serial)
        }
    }

    /// 48 kHz の float にして書く。speed はこの音の再生の速さ（1 サンプルで進むメディアの時刻を決める）
    private func convert(_ source: UnsafeMutablePointer<AVFrame>, time: Double?, speed: Double, serial: Int) {
        do {
            try resampler.convert(source) { channels, count, changed in
                if changed {
                    processor.configure(input: resampler.layout)
                }
                write(channels, count: count, time: time, speed: speed, serial: serial)
            }
        } catch {
            return
        }
    }

    /// 音響処理に通して輪のバッファへ書く。区間の始まりなら時刻の対応を決め、途中なら時刻とのずれを直す
    private func write(_ channels: [UnsafePointer<Float>], count: Int, time: Double?, speed: Double, serial: Int) {
        let secondsPerFrame = speed / Double(AudioResampler.sampleRate)
        var skip = 0
        if timeline.current == nil {
            // 正確なシーク：シーク先をまたぐフレームは頭を切る（鳴らすサンプルの数で）
            if let target = control.seekTarget(for: serial), let time, time < target {
                skip = Int((target - time) / secondsPerFrame)
            }
            guard skip < count else {
                return
            }
            let start = (time ?? 0) + Double(skip) * secondsPerFrame
            timeline.set(AudioTimeline.Base(ringIndex: ring.writtenFrames, time: start, secondsPerFrame: secondsPerFrame, serial: serial))
            writtenInSegment = 0
        } else if let time {
            skip = followTimestamp(time, serial: serial)
        }
        var offset = skip
        while offset < count, isCurrent(serial) {
            let chunk = min(count - offset, feeds.frames)
            processor.process(input: channels.map { $0 + offset }, frames: chunk, output: feeds.pointers)
            guard push(frames: chunk, serial: serial) else {
                return
            }
            offset += chunk
            writtenInSegment += chunk
        }
    }

    /// 区間の途中で、音の時刻（pts）と書いた数から決まる時刻がずれたとき：音の切れ目は無音で埋め、重なった分は捨てる
    /// （捨てる数を返す）。大きく飛んだときは、時刻の対応を決め直す
    private func followTimestamp(_ time: Double, serial: Int) -> Int {
        guard let base = timeline.current else {
            return 0
        }
        let spacing = base.secondsPerFrame
        let drift = time - (base.time + Double(writtenInSegment) * spacing)
        if abs(drift) > Self.maxGap {
            timeline.set(AudioTimeline.Base(ringIndex: ring.writtenFrames, time: time, secondsPerFrame: spacing, serial: serial))
            writtenInSegment = 0
        } else if drift > Self.driftTolerance {
            writeSilence(frames: Int(drift / spacing), serial: serial)
        } else if drift < -Self.driftTolerance {
            return Int(-drift / spacing)
        }
        return 0
    }

    /// 無音を音響処理に通して書く（音の切れ目・ファイルの終わりで音響処理の中に残った分を押し出す）
    private func writeSilence(frames: Int, serial: Int) {
        let silence = PlanarFeeds(count: max(resampler.channelCount, 1), frames: feeds.frames)
        let input = silence.pointers.map { UnsafePointer($0) }
        var remaining = frames
        while remaining > 0, isCurrent(serial) {
            let chunk = min(remaining, feeds.frames)
            processor.process(input: input, frames: chunk, output: feeds.pointers)
            guard push(frames: chunk, serial: serial) else {
                return
            }
            remaining -= chunk
            writtenInSegment += chunk
        }
    }

    /// 輪のバッファに書く。空きが無ければ待つ（シーク・閉じた・トラックを替えたら false）
    private func push(frames: Int, serial: Int) -> Bool {
        var done = 0
        while done < frames {
            if !isCurrent(serial) {
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
        writeSilence(frames: CinemaProcessor.latencyFrames, serial: serial)
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
