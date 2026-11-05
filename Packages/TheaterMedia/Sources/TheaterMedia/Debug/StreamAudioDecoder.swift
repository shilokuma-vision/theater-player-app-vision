//
//  StreamAudioDecoder.swift
//  TheaterMedia
//
//  デバッグ用（デバッグのビルドだけ。リリースには入れない）：少しずつ届く音声の入れ物の断片（Media Source Extensions に入れる
//  WebM・MP4 の初期化の断片と、続きの断片）を読んでデコードし、48 kHz・ステレオの float にする。
//  アプリのデバッグ用の YouTube の「映画館の音響に通す」が、ページの MSE に入る音声を写して渡す。
//
//  初期化の断片から読み直す（start）たびに、読むスレッドを 1 本作る。届いた断片はつなげて 1 本の流れとして読む
//  （シークのあとは、時刻の飛んだ断片が続く。WebM の Cluster・MP4 の moof はそれぞれ時刻を持つので、そのまま読める）。
//  届くまで読み手を待たせる（FFmpeg のデマクサーは、待たせる読み方を前提にしている）。シークはできない入れ物として読む。
//

#if DEBUG
import CFFmpeg
import Foundation

public final class StreamAudioDecoder: @unchecked Sendable {
    /// デコードした音（48 kHz・ステレオ）。time は最初のサンプルのメディアの時刻（秒。断片の timestampOffset を足した物）
    public typealias Output = @Sendable (_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ frames: Int, _ time: Double) -> Void

    /// 読み始めた・読めなかった
    public enum Status: Sendable, Equatable {
        /// 入れ物の形式・デコーダーの名前・サンプルレート・チャンネル数（matroska,webm・opus 48000 Hz 2 ch など）
        case opened(String)
        /// 開けない・音声が無い（FFmpeg のエラーの説明）
        case failed(String)
    }

    private let output: Output
    private let status: @Sendable (Status) -> Void
    private let lock = NSLock()
    private var input: StreamInput?

    public init(output: @escaping Output, status: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.output = output
        self.status = status
        tp_quiet_logs()
    }

    deinit {
        stop()
    }

    /// 初期化の断片から読み直す（読んでいた流れは捨てる）
    public func start(initialization data: Data, timestampOffset: Double) {
        let next = StreamInput()
        next.append(data, offset: timestampOffset)
        lock.withLock {
            input?.close()
            input = next
        }
        let output = output
        let status = status
        let thread = Thread {
            StreamAudioSession(input: next, output: output, status: status).run()
        }
        thread.name = "TheaterMedia.StreamAudioDecoder"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// 続きの断片（初期化の断片の前に届いた物は捨てる）
    public func append(_ data: Data, timestampOffset: Double) {
        lock.withLock { input }?.append(data, offset: timestampOffset)
    }

    /// 読むのをやめる
    public func stop() {
        lock.withLock {
            input?.close()
            input = nil
        }
    }
}

/// 届いた断片をつなげた流れ。書き手はメインスレッド、読み手は読むスレッド（届くまで待つ）
final class StreamInput: @unchecked Sendable {
    private let condition = NSCondition()
    private var chunks: [(data: Data, offset: Double)] = []
    private var position = 0
    private var closed = false
    /// 読んでいる断片の timestampOffset
    private var offset = 0.0

    func append(_ data: Data, offset: Double) {
        condition.withLock {
            guard !closed, !data.isEmpty else {
                return
            }
            chunks.append((data, offset))
            condition.signal()
        }
    }

    func close() {
        condition.withLock {
            closed = true
            chunks.removeAll()
            condition.broadcast()
        }
    }

    var currentOffset: Double {
        condition.withLock { offset }
    }

    var isClosed: Bool {
        condition.withLock { closed }
    }

    /// size バイトまで読む（届くまで待つ）。閉じたら AVERROR_EOF
    func read(into buffer: UnsafeMutablePointer<UInt8>, size: Int) -> Int32 {
        condition.withLock {
            while chunks.isEmpty, !closed {
                condition.wait()
            }
            guard let first = chunks.first, !closed else {
                return tp_error_eof()
            }
            offset = first.offset
            let count = min(size, first.data.count - position)
            first.data.withUnsafeBytes { bytes in
                buffer.update(from: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self) + position, count: count)
            }
            position += count
            if position == first.data.count {
                chunks.removeFirst()
                position = 0
            }
            return Int32(count)
        }
    }
}

/// FFmpeg が読む（avio_alloc_context の read_packet）。opaque は StreamInput
private func streamRead(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque, let buffer else {
        return tp_error_eof()
    }
    return Unmanaged<StreamInput>.fromOpaque(opaque).takeUnretainedValue().read(into: buffer, size: Int(size))
}

/// 1 本の流れを読んでデコードする（読むスレッドの中だけで使う）
private final class StreamAudioSession {
    private let input: StreamInput
    private let output: StreamAudioDecoder.Output
    private let status: @Sendable (StreamAudioDecoder.Status) -> Void
    private var resampler: OpaquePointer?
    private var resamplerKey: [Int32] = []
    private var left = [Float]()
    private var right = [Float]()

    init(
        input: StreamInput,
        output: @escaping StreamAudioDecoder.Output,
        status: @escaping @Sendable (StreamAudioDecoder.Status) -> Void
    ) {
        self.input = input
        self.output = output
        self.status = status
    }

    deinit {
        swr_free(&resampler)
    }

    func run() {
        let bufferSize: Int32 = 16_384
        guard let buffer = av_malloc(Int(bufferSize))?.assumingMemoryBound(to: UInt8.self) else {
            return
        }
        let opaque = Unmanaged.passRetained(input).toOpaque()
        defer { Unmanaged<StreamInput>.fromOpaque(opaque).release() }
        var io = avio_alloc_context(buffer, bufferSize, 0, opaque, streamRead, nil, nil)
        guard let context = io else {
            av_free(buffer)
            return
        }
        defer {
            av_freep(&context.pointee.buffer)
            avio_context_free(&io)
        }
        var format = avformat_alloc_context()
        guard let allocated = format else {
            return
        }
        allocated.pointee.pb = context
        allocated.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        var options: OpaquePointer?
        // 初期化の断片は小さい（数百バイト〜数 KB）。形式を調べるために、続きの断片を長く待たない
        // （WebM・MP4 は先頭で分かる。分かりにくい形式でも、既定の 1 MB まで待たない）
        av_dict_set(&options, "formatprobesize", "32768", 0)
        av_dict_set(&options, "probesize", "32768", 0)
        av_dict_set(&options, "analyzeduration", "500000", 0)
        let result = avformat_open_input(&format, nil, nil, &options)
        av_dict_free(&options)
        guard result >= 0, let opened = format else {
            // 閉じた（読み直した・やめた）ときは知らせない
            if !input.isClosed {
                status(.failed(ffmpegErrorString(result)))
            }
            return
        }
        defer { avformat_close_input(&format) }
        decode(opened)
    }

    private func decode(_ format: UnsafeMutablePointer<AVFormatContext>) {
        var decoder: UnsafePointer<AVCodec>?
        var index = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0)
        if index < 0 {
            // 見出しにサンプルレート・チャンネル数の無い形式（生の AAC・AC-3 など）は選ばれないので、少し読んで調べる
            // （WebM・MP4 は見出しに書いてある。読んだパケットは、あとで av_read_frame が返す）
            avformat_find_stream_info(format, nil)
            index = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0)
        }
        let formatName = format.pointee.iformat.map { String(cString: $0.pointee.name) } ?? "?"
        guard index >= 0, let decoder, let stream = format.pointee.streams[Int(index)] else {
            status(.failed("\(formatName)・\(ffmpegErrorString(index))"))
            return
        }
        var codec = avcodec_alloc_context3(decoder)
        guard let codecContext = codec,
              avcodec_parameters_to_context(codecContext, stream.pointee.codecpar) >= 0,
              avcodec_open2(codecContext, decoder, nil) >= 0 else {
            avcodec_free_context(&codec)
            return
        }
        defer { avcodec_free_context(&codec) }
        codecContext.pointee.pkt_timebase = stream.pointee.time_base
        let channels = codecContext.pointee.ch_layout.nb_channels
        status(.opened("\(formatName)・\(String(cString: decoder.pointee.name)) \(codecContext.pointee.sample_rate) Hz \(channels) ch"))
        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        defer {
            av_packet_free(&packet)
            av_frame_free(&frame)
        }
        guard let packet, let frame else {
            return
        }
        let timeBase = av_q2d(stream.pointee.time_base)
        // 時刻の無いフレームは、前のフレームの続きとみなす
        var nextTime: Double?
        while av_read_frame(format, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == index, avcodec_send_packet(codecContext, packet) >= 0 else {
                continue
            }
            let offset = input.currentOffset
            while avcodec_receive_frame(codecContext, frame) >= 0 {
                defer { av_frame_unref(frame) }
                let stamp = frame.pointee.best_effort_timestamp
                let time = stamp != tp_no_pts() ? Double(stamp) * timeBase + offset : nextTime ?? offset
                convert(frame, time: time)
                if frame.pointee.sample_rate > 0 {
                    nextTime = time + Double(frame.pointee.nb_samples) / Double(frame.pointee.sample_rate)
                }
            }
        }
    }

    /// 48 kHz・ステレオの float にして渡す（5.1 などはステレオにまとめる）
    private func convert(_ frame: UnsafeMutablePointer<AVFrame>, time: Double) {
        let key = [frame.pointee.format, frame.pointee.sample_rate, frame.pointee.ch_layout.nb_channels]
        if key != resamplerKey {
            guard prepare(frame) else {
                return
            }
            resamplerKey = key
        }
        let capacity = Int(swr_get_out_samples(resampler, frame.pointee.nb_samples))
        if left.count < capacity {
            left = [Float](repeating: 0, count: capacity)
            right = [Float](repeating: 0, count: capacity)
        }
        let converted = left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer -> Int32 in
                var planes: [UnsafeMutablePointer<UInt8>?] = [
                    UnsafeMutableRawPointer(leftBuffer.baseAddress!).assumingMemoryBound(to: UInt8.self),
                    UnsafeMutableRawPointer(rightBuffer.baseAddress!).assumingMemoryBound(to: UInt8.self)
                ]
                let channels = Int(frame.pointee.ch_layout.nb_channels)
                return planes.withUnsafeMutableBufferPointer { output in
                    frame.pointee.extended_data.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: channels) {
                        swr_convert(resampler, output.baseAddress, Int32(capacity), $0, frame.pointee.nb_samples)
                    }
                }
            }
        }
        // 読み直した・やめた流れ（閉じた）は、もう読んであった分も出さない（次の動画の音に、前の動画の音が混ざらないように）
        guard converted > 0, !input.isClosed else {
            return
        }
        left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                output(leftBuffer.baseAddress!, rightBuffer.baseAddress!, Int(converted), time)
            }
        }
    }

    private func prepare(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        swr_free(&resampler)
        var input = AVChannelLayout()
        if frame.pointee.ch_layout.order == AV_CHANNEL_ORDER_UNSPEC {
            av_channel_layout_default(&input, frame.pointee.ch_layout.nb_channels)
        } else if av_channel_layout_copy(&input, &frame.pointee.ch_layout) < 0 {
            return false
        }
        defer { av_channel_layout_uninit(&input) }
        var stereo = AVChannelLayout()
        av_channel_layout_default(&stereo, 2)
        defer { av_channel_layout_uninit(&stereo) }
        let configured = swr_alloc_set_opts2(
            &resampler,
            &stereo,
            AV_SAMPLE_FMT_FLTP,
            AudioResampler.sampleRate,
            &input,
            AVSampleFormat(rawValue: frame.pointee.format),
            frame.pointee.sample_rate,
            0,
            nil
        )
        return configured >= 0 && swr_init(resampler) >= 0
    }
}
#endif
