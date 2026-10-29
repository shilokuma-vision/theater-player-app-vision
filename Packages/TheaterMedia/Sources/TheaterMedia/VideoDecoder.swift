//
//  VideoDecoder.swift
//  TheaterMedia
//
//  映像のデコード（自分のスレッドで回す）。VideoToolbox（ハードウェア）で扱える形式は VideoToolbox で、それ以外はソフトウェアでデコードする。
//  VideoToolbox で 1 コマも出ないまま続くときは、ソフトウェアのデコーダーで開き直す。
//  インターレースの映像はソフトウェアでデコードして bwdif でプログレッシブにする。
//  フレームはスクリーンの光（3 区画の色）を測ってから、VideoOutput に時刻付きで渡す。
//

import CFFmpeg
import CoreVideo
import Foundation
import Synchronization

final class VideoDecoder: @unchecked Sendable {
    let streamIndex: Int
    private let timeBase: AVRational
    private let startTime: Double
    private let frameDuration: Double
    private var codec: UnsafeMutablePointer<AVCodecContext>
    private let stream: UnsafeMutablePointer<AVStream>
    /// VideoToolbox で、前のコマが出てから送ったパケットの数（多すぎたらソフトウェアに替える）
    private var packetsWithoutFrame = 0
    /// 診断用の数（時計のスレッドが読む）
    let stats = Mutex(VideoStats())
    private let frame: UnsafeMutablePointer<AVFrame>
    private let interlaced: Bool
    private let rotation: Int
    private let isHDR: Bool
    private let maker = PixelBufferMaker()
    private var deinterlacer: Deinterlacer?
    private var decoderSerial = -1
    private var waitingFirstFrame = true
    private var lastTime: Double?
    private var reportedFormat: VideoFormat?
    let queue = PacketQueue()
    let output: VideoOutput
    let lights: ScreenLightTimeline
    private let control: PlaybackControl
    /// 映像の形式が分かった・変わった
    var onFormat: (@Sendable (VideoFormat) -> Void)?

    init(
        stream: UnsafeMutablePointer<AVStream>,
        index: Int,
        startTime: Double,
        control: PlaybackControl,
        output: VideoOutput,
        lights: ScreenLightTimeline
    ) throws {
        let parameters = stream.pointee.codecpar.pointee
        guard let decoder = avcodec_find_decoder(parameters.codec_id), let context = avcodec_alloc_context3(decoder),
              let frame = av_frame_alloc() else {
            throw MediaError("この映像の形式には対応していません")
        }
        // 先にすべての値を決める（この後で失敗しても deinit が context・frame を解放する）
        codec = context
        self.frame = frame
        self.stream = stream
        let fieldOrder = parameters.field_order
        interlaced = fieldOrder != AV_FIELD_UNKNOWN && fieldOrder != AV_FIELD_PROGRESSIVE
        streamIndex = index
        timeBase = stream.pointee.time_base
        self.startTime = startTime
        let rate = av_q2d(stream.pointee.avg_frame_rate)
        frameDuration = rate > 1 ? 1 / rate : 1 / 24
        rotation = MediaTracks.rotation(of: stream)
        isHDR = parameters.color_trc == AVCOL_TRC_SMPTE2084 || parameters.color_trc == AVCOL_TRC_ARIB_STD_B67
        self.control = control
        self.output = output
        self.lights = lights
        try check(avcodec_parameters_to_context(context, stream.pointee.codecpar), "映像の設定")
        context.pointee.pkt_timebase = stream.pointee.time_base
        context.pointee.thread_count = 0
        if !interlaced {
            Self.attachVideoToolbox(context)
        }
        try check(avcodec_open2(context, decoder, nil), "映像のデコーダーを開けません")
    }

    deinit {
        var context: UnsafeMutablePointer<AVCodecContext>? = codec
        avcodec_free_context(&context)
        var pointer: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&pointer)
    }

    private static func attachVideoToolbox(_ context: UnsafeMutablePointer<AVCodecContext>) {
        var device: UnsafeMutablePointer<AVBufferRef>?
        guard av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 else {
            return
        }
        context.pointee.hw_device_ctx = av_buffer_ref(device)
        av_buffer_unref(&device)
        tp_use_videotoolbox(context)
    }

    // MARK: - スレッド

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
                let sent = avcodec_send_packet(codec, packet)
                if sent >= 0 {
                    receiveFrames(serial: serial)
                }
                fallBackIfHardwareFails(sent: sent)
            case let .endOfStream(serial):
                guard serial == control.serial else {
                    continue
                }
                prepare(serial: serial)
                avcodec_send_packet(codec, nil)
                receiveFrames(serial: serial)
                avcodec_flush_buffers(codec)
                decoderSerial = -1
                control.markEnded(.video, serial: serial)
            }
        }
    }

    /// 番号が変わったら（シークの直後）、デコーダーと出口を空にする
    private func prepare(serial: Int) {
        guard serial != decoderSerial else {
            return
        }
        if decoderSerial >= 0 {
            avcodec_flush_buffers(codec)
        }
        decoderSerial = serial
        packetsWithoutFrame = 0
        deinterlacer = nil
        waitingFirstFrame = true
        lastTime = nil
        output.flush()
        lights.clear()
    }

    private func receiveFrames(serial: Int) {
        while serial == control.serial, avcodec_receive_frame(codec, frame) >= 0 {
            defer { av_frame_unref(frame) }
            packetsWithoutFrame = 0
            let hardware = tp_uses_videotoolbox(codec) != 0
            stats.withLock {
                $0.decoded += 1
                $0.usesVideoToolbox = hardware
            }
            if interlaced, frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0 || deinterlacer != nil {
                deinterlace(frame, serial: serial)
            } else {
                deliver(frame, timeBase: timeBase, serial: serial)
            }
        }
    }

    /// VideoToolbox で 1 コマも出ないまま、これだけのパケットを送ったら諦める（2 秒前後。シークの直後でも、ふつうは数パケットで出る）
    private static let hardwareGiveUpPackets = 48

    /// VideoToolbox が解けない形式だった（get_format で除けなかったもの）ときに、ソフトウェアのデコーダーで開き直す。
    /// 開き直したあとは、次のキーフレームから映る
    private func fallBackIfHardwareFails(sent: Int32) {
        guard tp_uses_videotoolbox(codec) != 0 else {
            return
        }
        // 送るのを断られた（デコードの失敗）ときは、早めに諦める
        packetsWithoutFrame += sent < 0 && sent != tp_error_again() ? 8 : 1
        guard packetsWithoutFrame >= Self.hardwareGiveUpPackets,
              let decoder = avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id),
              let context = avcodec_alloc_context3(decoder) else {
            return
        }
        var replacement: UnsafeMutablePointer<AVCodecContext>? = context
        context.pointee.pkt_timebase = stream.pointee.time_base
        context.pointee.thread_count = 0
        guard avcodec_parameters_to_context(context, stream.pointee.codecpar) >= 0,
              avcodec_open2(context, decoder, nil) >= 0 else {
            avcodec_free_context(&replacement)
            packetsWithoutFrame = 0
            return
        }
        var old: UnsafeMutablePointer<AVCodecContext>? = codec
        avcodec_free_context(&old)
        codec = context
        packetsWithoutFrame = 0
    }

    private func deinterlace(_ source: UnsafeMutablePointer<AVFrame>, serial: Int) {
        if let current = deinterlacer, !current.matches(source) {
            // 大きさ・画素の形式が変わった：作り直す（bwdif は途中の変化に対応していない）
            deinterlacer = nil
        }
        if deinterlacer == nil {
            deinterlacer = try? Deinterlacer(
                width: source.pointee.width,
                height: source.pointee.height,
                format: source.pointee.format,
                timeBase: timeBase,
                aspect: source.pointee.sample_aspect_ratio
            )
        }
        guard let deinterlacer else {
            deliver(source, timeBase: timeBase, serial: serial)
            return
        }
        // bwdif は pts だけを出口の時刻の単位（入力の半分）に直し、best_effort_timestamp は入力の単位のまま写す。
        // best_effort_timestamp を pts にして入れ、出てきたフレームは pts を時刻にする
        if source.pointee.best_effort_timestamp != tp_no_pts() {
            source.pointee.pts = source.pointee.best_effort_timestamp
        }
        let base = deinterlacer.timeBase
        deinterlacer.process(source) { output in
            output.pointee.best_effort_timestamp = output.pointee.pts
            deliver(output, timeBase: base, serial: serial)
        }
    }

    // MARK: - フレームを渡す

    private func deliver(_ decoded: UnsafeMutablePointer<AVFrame>, timeBase base: AVRational, serial: Int) {
        let time = frameTime(decoded, timeBase: base)
        let duration = decoded.pointee.duration > 0 ? Double(decoded.pointee.duration) * av_q2d(base) : frameDuration
        lastTime = time
        if let target = control.seekTarget(for: serial), time + duration < target {
            stats.withLock { $0.droppedBeforeSeekTarget += 1 }
            return
        }
        guard let buffer = pixelBuffer(of: decoded) else {
            stats.withLock { $0.noPixelBuffer += 1 }
            return
        }
        report(decoded)
        let light = ScreenLightSampler.sample(buffer)
        guard waitUntilReady(time: time, serial: serial) else {
            return
        }
        // 遅れたフレームは飛ばす（デコードが追いつかないとき）。シーク直後の 1 枚目は必ず出す
        if !waitingFirstFrame, !control.isPaused, time + duration < output.time - 0.15 {
            stats.withLock {
                $0.droppedLate += 1
                $0.lastFrameTime = time
            }
            return
        }
        stats.withLock {
            $0.enqueued += 1
            $0.lastFrameTime = time
        }
        lights.append(time: time, light: light)
        output.enqueue(DecodedVideoFrame(pixelBuffer: buffer, time: time, duration: duration, serial: serial),
                       displayImmediately: waitingFirstFrame && control.isPaused)
        waitingFirstFrame = false
    }

    private func frameTime(_ decoded: UnsafeMutablePointer<AVFrame>, timeBase base: AVRational) -> Double {
        var stamp = decoded.pointee.best_effort_timestamp
        if stamp == tp_no_pts() {
            stamp = decoded.pointee.pts
        }
        guard stamp != tp_no_pts() else {
            return (lastTime ?? 0) + frameDuration
        }
        return Double(stamp) * av_q2d(base) - startTime
    }

    private func pixelBuffer(of decoded: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        if let hardware = tp_frame_pixel_buffer(decoded) {
            let buffer = hardware.takeUnretainedValue()
            av_vt_pixbuf_set_attachments(nil, buffer, decoded)
            return buffer
        }
        return maker.make(from: decoded)
    }

    /// 出口が受け取れるまで待つ（止まっている・シークした・閉じたら false）
    /// 表示の時計よりこれ以上先のコマは、まだ渡さない（秒）。renderer は isReadyForMoreMediaData が true のまま
    /// 何十秒も先のコマを受け取ることがあり（シークの後など）、溜めすぎると近い時刻のコマが捨てられて画面が真っ黒になる。
    /// VideoToolbox の画素の領域も、renderer が持ったままのコマで尽きてデコードが止まる
    private static let maxAhead = 0.5

    /// time のコマを渡してよくなるまで待つ（シーク・止める・トラックを替えたら false）。シーク直後の 1 枚目はすぐ渡す
    private func waitUntilReady(time: Double, serial: Int) -> Bool {
        while !output.isReady || (!waitingFirstFrame && time > output.time + Self.maxAhead) {
            if control.isStopped || serial != control.serial || !active.load(ordering: .acquiring) {
                return false
            }
            Thread.sleep(forTimeInterval: 0.004)
        }
        return serial == control.serial
    }

    private func report(_ decoded: UnsafeMutablePointer<AVFrame>) {
        let width = Int(decoded.pointee.width)
        let height = Int(decoded.pointee.height)
        let aspect = decoded.pointee.sample_aspect_ratio
        let pixelAspect = aspect.num > 0 && aspect.den > 0 ? av_q2d(aspect) : 1
        let format = VideoFormat(
            width: width,
            height: height,
            displayAspect: Double(width) * pixelAspect / Double(max(height, 1)),
            rotation: rotation,
            isHDR: isHDR
        )
        if format != reportedFormat {
            reportedFormat = format
            onFormat?(format)
        }
    }
}
