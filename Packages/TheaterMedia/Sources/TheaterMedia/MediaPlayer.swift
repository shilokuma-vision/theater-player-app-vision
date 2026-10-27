//
//  MediaPlayer.swift
//  TheaterMedia
//
//  動画・音楽の再生の入口。VLC と同じく FFmpeg で開くので、MKV・AVI・WMV・TS・FLAC・DTS・TrueHD なども再生できる。
//
//  - 映像：videoRenderer（AVSampleBufferVideoRenderer）を RealityKit の VideoMaterial に渡すと、スクリーンに映る
//  - 音声：映画館の音響処理（processor）を通した、スピーカーごとの信号が ring に入る。RealityKit の空間オーディオの音源が ring から読む
//  - 時計：音が鳴っていれば音の時計（ring が実際に鳴らした位置）に、映像の時計を合わせる（音が主）。音が無い・鳴り終えた・
//    データが来ないときは映像の時計で進む
//

@preconcurrency import AVFoundation
import CFFmpeg
import CinemaAudio
import Foundation

/// 再生の知らせ
public enum MediaPlayerEvent: Sendable {
    case state(PlaybackState)
    case videoFormat(VideoFormat)
    case error(String)
}

public final class MediaPlayer: @unchecked Sendable {
    public let processor: CinemaProcessor
    public let ring: SpeakerFeedRing
    let videoOutput = VideoOutput()
    let lights = ScreenLightTimeline()
    let audioTimeline = AudioTimeline()
    let subtitleStore = SubtitleStore()
    let lock = NSLock()
    /// 再生の操作（開く・閉じる・再生・一時停止・シーク・時計の 1 回）を 1 つずつ行う（時計のスレッドが一時停止を上書きしないため）
    let controlLock = NSRecursiveLock()
    var session: PlaybackSession?
    var stateValue: PlaybackState = .idle
    var rateValue: Float = 1
    var pausedTime: Double = 0
    var clockThread: Thread?
    /// 開く・閉じるたびに増える番号。後から別のファイルを開いたら、前の open の結果は捨てる
    var openGeneration = 0
    /// 別のファイルの字幕を出している（シークで消さない）
    var showsExternalSubtitles = false
    /// 音のデータが来ず、映像の時計で進めている（音がたまる・シークで戻す）
    var audioStarved = false
    /// 輪のバッファを鳴らし始めたホストの時刻（それより前の描画の回は、止める前の古い位置）
    var ringStartHost: UInt64 = 0
    var settings = PlayerTiming()
    public let events: AsyncStream<MediaPlayerEvent>
    let continuation: AsyncStream<MediaPlayerEvent>.Continuation

    /// speakers：空間オーディオの音源の系統の並び（ring の信号の順）
    public init(speakers: [CinemaBus]) throws {
        processor = try CinemaProcessor(speakers: speakers)
        ring = SpeakerFeedRing(feeds: speakers.count)
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    deinit {
        close()
        continuation.finish()
    }

    /// RealityKit の VideoMaterial(videoRenderer:) に渡す
    public var videoRenderer: AVSampleBufferVideoRenderer {
        videoOutput.renderer
    }

    public var state: PlaybackState {
        lock.lock()
        defer { lock.unlock() }
        return stateValue
    }

    func setState(_ newState: PlaybackState) {
        lock.lock()
        let changed = stateValue != newState
        stateValue = newState
        lock.unlock()
        if changed {
            continuation.yield(.state(newState))
        }
    }

    // MARK: - 開く・閉じる

    /// ファイルを開き、最初の画を出して止まった状態にする
    public func open(_ url: URL) async throws -> MediaInfo {
        close()
        setState(.opening)
        do {
            let opened = try await Task.detached(priority: .userInitiated) { try Self.makeSession(url: url) }.value
            try start(opened)
            return opened.info
        } catch {
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    private static func makeSession(url: URL) throws -> PlaybackSession {
        let container = try MediaContainer(url: url)
        let info = MediaInfo(
            duration: container.duration,
            title: container.metadata("title"),
            artist: container.metadata("artist") ?? container.metadata("album_artist"),
            album: container.metadata("album"),
            container: container.formatName,
            videoTracks: MediaTracks.video(container),
            audioTracks: MediaTracks.audio(container),
            subtitleTracks: MediaTracks.subtitles(container),
            chapters: container.chapters,
            artwork: container.artwork
        )
        guard !info.videoTracks.isEmpty || !info.audioTracks.isEmpty else {
            throw MediaError("映像も音声も見つかりません")
        }
        return PlaybackSession(container: container, info: info)
    }

    private func start(_ newSession: PlaybackSession) throws {
        subtitleStore.clear()
        lights.clear()
        audioTimeline.reset()
        ring.setPaused(true)
        ring.flush()
        videoOutput.flush(removingImage: true)
        videoOutput.setRate(0, time: 0)
        if let track = Self.preferredVideo(newSession.info) {
            try newSession.setVideo(makeVideoDecoder(newSession, index: track.id))
        }
        if let track = Self.preferredAudio(newSession.info) {
            newSession.setAudio(try makeAudioDecoder(newSession, index: track.id))
        }
        if let track = newSession.info.subtitleTracks.first(where: { $0.isForced || $0.isDefault }) {
            newSession.setSubtitle(try? makeSubtitleDecoder(newSession, index: track.id))
        }
        lock.lock()
        session = newSession
        pausedTime = 0
        lock.unlock()
        newSession.control.isPaused = true
        newSession.startReading()
        startClock()
        setState(.paused)
    }

    /// 再生を止めて、開いていたファイルを閉じる
    public func close() {
        lock.lock()
        let old = session
        session = nil
        let thread = clockThread
        clockThread = nil
        lock.unlock()
        thread?.cancel()
        old?.stop()
        ring.setPaused(true)
        ring.flush()
        videoOutput.setRate(0, time: 0)
        videoOutput.flush(removingImage: true)
        if old != nil {
            setState(.idle)
        }
    }

    static func preferredVideo(_ info: MediaInfo) -> VideoTrack? {
        info.videoTracks.first
    }

    /// 音声：既定の印のあるトラック、無ければ最初
    static func preferredAudio(_ info: MediaInfo) -> AudioTrack? {
        info.audioTracks.first { $0.isDefault } ?? info.audioTracks.first
    }

    func makeVideoDecoder(_ session: PlaybackSession, index: Int) throws -> VideoDecoder? {
        guard let stream = session.container.stream(index) else {
            return nil
        }
        let decoder = try VideoDecoder(
            stream: stream,
            index: index,
            startTime: session.startTime,
            control: session.control,
            output: videoOutput,
            lights: lights
        )
        decoder.onFormat = { [weak self] format in
            self?.continuation.yield(.videoFormat(format))
        }
        return decoder
    }

    func makeAudioDecoder(_ session: PlaybackSession, index: Int) throws -> AudioDecoder? {
        guard let stream = session.container.stream(index) else {
            return nil
        }
        let decoder = try AudioDecoder(
            stream: stream,
            index: index,
            startTime: session.startTime,
            control: session.control,
            processor: processor,
            ring: ring,
            timeline: audioTimeline
        )
        decoder.playbackRate = Double(rate)
        return decoder
    }

    func makeSubtitleDecoder(_ session: PlaybackSession, index: Int) throws -> SubtitleDecoder? {
        guard let stream = session.container.stream(index) else {
            return nil
        }
        let decoder = try SubtitleDecoder(stream: stream, index: index, startTime: session.startTime, store: subtitleStore)
        if let video = session.info.videoTracks.first, video.width > 0, decoder.canvas == CGSize(width: 1_920, height: 1_080) {
            decoder.canvas = CGSize(width: video.width, height: video.height)
        }
        return decoder
    }
}

/// 時計の調整の値
struct PlayerTiming {
    /// RealityKit の空間オーディオが音を出すまでの遅れの見込み（秒）
    var audioOutputLatency: Double = 0.04
    /// 利用者が合わせる音の遅れ（秒。正なら音を遅らせる）
    var audioDelay: Double = 0
    /// 利用者が合わせる字幕の遅れ（秒）
    var subtitleDelay: Double = 0
}
