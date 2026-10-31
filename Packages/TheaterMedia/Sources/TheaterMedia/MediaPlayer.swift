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
    /// 3D の選び方と、今のファイルを映す並べ方・ファイルの名前（MediaPlayer+Stereo）
    var stereoModeValue = StereoMode.auto
    var stereoValue = StereoPacking.mono
    var fileName = ""
    /// 音のデータが来ず、映像の時計で進めている（音がたまる・シークで戻す）
    var audioStarved = false
    /// 輪のバッファを鳴らし始めたホストの時刻（それより前の描画の回は、止める前の古い位置）
    var ringStartHost: UInt64 = 0
    /// 前に診断のログを書いたホストの時刻
    var lastDiagnosticsHost: UInt64 = 0
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

    /// スクリーンをつなぐ。body で、渡した renderer の VideoMaterial(videoRenderer:) を作る
    /// （コマを渡していない間に行う。渡している最中だと落ちる・映らない）。つないだあとからコマを渡す。
    /// 前のスクリーンにつないだ renderer は使わず、新しい renderer を渡す（videoRenderer が変わる）
    public func attachVideoScreen(_ body: (AVSampleBufferVideoRenderer) -> Void) {
        videoOutput.attachScreen(body)
    }

    /// スクリーンを外す（映画館を閉じた・舞台を作り直す）。次にスクリーンをつなぐまで、コマを渡さない
    public func detachVideoScreen() {
        videoOutput.detachScreen()
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
        let generation = closeSession()
        lock.withLock { fileName = url.lastPathComponent }
        setState(.opening)
        do {
            let opened = try await Task.detached(priority: .userInitiated) { try Self.makeSession(url: url) }.value
            try start(opened, generation: generation)
            return opened.info
        } catch {
            controlLock.withLock {
                if lock.withLock({ openGeneration == generation }) {
                    setState(.failed(error.localizedDescription))
                }
            }
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
            throw MediaError(localized: "No video or audio found.")
        }
        return PlaybackSession(container: container, info: info)
    }

    private func start(_ newSession: PlaybackSession, generation: Int) throws {
        controlLock.lock()
        defer { controlLock.unlock() }
        // 開いている間に、別のファイルを開いた・閉じた：この結果は使わない
        guard lock.withLock({ openGeneration == generation }) else {
            throw CancellationError()
        }
        stopSession()
        subtitleStore.clear()
        lights.clear()
        audioTimeline.reset()
        ring.setPaused(true)
        ring.flush()
        // 表示中の絵は消さない（flush(removingDisplayedImage:) の後、RealityKit の VideoMaterial が次の絵を映さなくなることがあった）。
        // 前のファイルの絵は、スクリーンを隠して見せない（TheaterStage）
        videoOutput.flush()
        videoOutput.setRate(0, time: 0)
        do {
            try attachDecoders(newSession)
        } catch {
            // 途中で失敗した：動き始めたデコードのスレッドを止める
            newSession.stop()
            throw error
        }
        lock.lock()
        session = newSession
        pausedTime = 0
        showsExternalSubtitles = false
        audioStarved = false
        lock.unlock()
        // 最初のフレームから立体の指定を付けるよう、読み始める前に並べ方を決める
        applyStereo()
        newSession.control.isPaused = true
        newSession.startReading()
        startClock()
        setState(.paused)
    }

    private func attachDecoders(_ newSession: PlaybackSession) throws {
        if let track = Self.preferredVideo(newSession.info) {
            try newSession.setVideo(makeVideoDecoder(newSession, index: track.id))
        }
        if let track = Self.preferredAudio(newSession.info) {
            newSession.setAudio(try makeAudioDecoder(newSession, index: track.id))
        }
        if let track = newSession.info.subtitleTracks.first(where: { $0.isForced || $0.isDefault }) {
            newSession.setSubtitle(try? makeSubtitleDecoder(newSession, index: track.id))
        }
    }

    /// 再生を止めて、開いていたファイルを閉じる
    public func close() {
        closeSession()
    }

    /// 閉じて、開く操作の番号を進める（進めた番号を返す。それより前に始めた open の結果は捨てる）
    @discardableResult
    private func closeSession() -> Int {
        controlLock.lock()
        defer { controlLock.unlock() }
        let generation = lock.withLock {
            openGeneration += 1
            return openGeneration
        }
        stopSession()
        return generation
    }

    /// 今のセッションと時計のスレッドを止める（スレッドは自分で抜ける）
    private func stopSession() {
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
        videoOutput.flush()
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
