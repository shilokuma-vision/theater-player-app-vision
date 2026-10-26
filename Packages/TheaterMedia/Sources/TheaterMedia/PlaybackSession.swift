//
//  PlaybackSession.swift
//  TheaterMedia
//
//  開いた 1 つのファイルの再生（入れ物・デコーダー・スレッド）。読み込みのスレッドがパケットを読み、
//  映像・音声・字幕のデコーダーへ振り分ける。シークの要求もこのスレッドで実行する。
//

import CFFmpeg
import Foundation

final class PlaybackSession: @unchecked Sendable {
    let container: MediaContainer
    let control = PlaybackControl()
    let info: MediaInfo
    /// メディアの時刻の原点（入れ物の start_time）
    let startTime: Double
    private let lock = NSLock()
    private var videoDecoder: VideoDecoder?
    private var audioDecoder: AudioDecoder?
    private var subtitleDecoder: SubtitleDecoder?
    private var pendingSeek: (time: Double, serial: Int)?
    /// 読み込みのスレッドが最後に実行したシークの番号（読んだパケットに付ける）
    private var demuxSerial = 0
    private var threads: [Thread] = []

    init(container: MediaContainer, info: MediaInfo) {
        self.container = container
        self.info = info
        let start = container.context.pointee.start_time
        startTime = start != tp_no_pts() && start > 0 ? Double(start) / Double(tp_time_base()) : 0
    }

    var video: VideoDecoder? {
        lock.lock()
        defer { lock.unlock() }
        return videoDecoder
    }

    var audio: AudioDecoder? {
        lock.lock()
        defer { lock.unlock() }
        return audioDecoder
    }

    var subtitle: SubtitleDecoder? {
        lock.lock()
        defer { lock.unlock() }
        return subtitleDecoder
    }

    // MARK: - デコーダー

    func setVideo(_ decoder: VideoDecoder?) {
        lock.lock()
        let old = videoDecoder
        videoDecoder = decoder
        lock.unlock()
        old?.deactivate()
        if let decoder {
            start(name: "TheaterMedia.video", priority: .userInteractive) { decoder.run() }
        }
    }

    func setAudio(_ decoder: AudioDecoder?) {
        lock.lock()
        let old = audioDecoder
        audioDecoder = decoder
        lock.unlock()
        old?.deactivate()
        if let decoder {
            start(name: "TheaterMedia.audio", priority: .userInteractive) { decoder.run() }
        }
    }

    func setSubtitle(_ decoder: SubtitleDecoder?) {
        lock.lock()
        defer { lock.unlock() }
        subtitleDecoder = decoder
    }

    func startReading() {
        start(name: "TheaterMedia.demux", priority: .userInitiated) { [weak self] in
            self?.readLoop()
        }
    }

    private func start(name: String, priority: QualityOfService, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = priority
        lock.lock()
        threads.append(thread)
        lock.unlock()
        thread.start()
    }

    /// 止める（スレッドは自分で抜ける）
    func stop() {
        control.stop()
        container.requestInterrupt()
        video?.queue.abort()
        audio?.queue.abort()
    }

    // MARK: - シーク

    /// シークを頼む（読み込みのスレッドが実行する）。新しい番号を返す
    func requestSeek(to time: Double) -> Int {
        let serial = control.beginSeek(to: time)
        lock.lock()
        pendingSeek = (time, serial)
        lock.unlock()
        return serial
    }

    private func takePendingSeek() -> (time: Double, serial: Int)? {
        lock.lock()
        defer { lock.unlock() }
        let seek = pendingSeek
        pendingSeek = nil
        return seek
    }

    // MARK: - 読み込みのスレッド

    private func readLoop() {
        guard let packet = av_packet_alloc() else {
            return
        }
        var pointer: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&pointer) }
        var ended = false
        while !control.isStopped {
            if let seek = takePendingSeek() {
                perform(seek)
                ended = false
                continue
            }
            if ended || isBackedUp {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            do {
                if try container.read(into: packet) {
                    route(packet)
                } else {
                    endOfStream()
                    ended = true
                }
            } catch {
                endOfStream()
                ended = true
            }
        }
    }

    /// 待ち行列がいっぱい（デコードが追いつくまで読まない）
    private var isBackedUp: Bool {
        (video?.queue.isFull ?? false) || (audio?.queue.isFull ?? false)
    }

    private func perform(_ seek: (time: Double, serial: Int)) {
        video?.queue.flush()
        audio?.queue.flush()
        try? container.seek(to: seek.time + startTime)
        lock.lock()
        demuxSerial = seek.serial
        lock.unlock()
    }

    private func route(_ packet: UnsafeMutablePointer<AVPacket>) {
        defer { av_packet_unref(packet) }
        let index = Int(packet.pointee.stream_index)
        lock.lock()
        let serial = demuxSerial
        lock.unlock()
        if let video, video.streamIndex == index {
            video.queue.put(copyOf: packet, serial: serial)
        } else if let audio, audio.streamIndex == index {
            audio.queue.put(copyOf: packet, serial: serial)
        } else if let subtitle, subtitle.streamIndex == index {
            subtitle.decode(packet)
        }
    }

    private func endOfStream() {
        lock.lock()
        let serial = demuxSerial
        lock.unlock()
        video?.queue.putEndOfStream(serial: serial)
        audio?.queue.putEndOfStream(serial: serial)
        control.markEnded(.demux, serial: serial)
    }
}
