//
//  YouTubeSound.swift
//  TheaterPlayer
//
//  デバッグ用（デバッグのビルドだけ。リリースには入れない）：YouTube のページの MSE から写した音声（YouTubeSoundScript）をデコードし、
//  ページの <video> の時計に合わせて、映画館の音響処理（CinemaProcessor）に通し、YouTube 用の輪のバッファ（ring）へ書く。
//  スイッチを入れているあいだは、空間オーディオの音源がこの ring を鳴らす（SpeakerRoute）。ステレオは、手元のファイルと同じく映画館向けに広げる。
//  YouTube の利用規約は、音や映像を切り離したり手を加えたりすることを禁じている。これは確認用で、利用者の判断で作った。配らない。
//
//  音と映像を合わせる：映像は WebView の中なので、アプリでは遅らせられない。代わりに、ページが先まで MSE に入れた音を持っておき、
//  今書く音が実際に聞こえる時刻（ring にたまった分・音響処理の遅れ・空間オーディオの出力の遅れの先）の、動画の時刻の音を書く。
//  書く位置と動画の時計が大きくずれたら（シーク・途切れ）、合わせ直す。速さを変えているあいだ（1 倍以外）は鳴らさない。
//
//  処理と ring は、再生のエンジン（MediaPlayer）の物と別に持つ。YouTube を開くと手元の動画は止まるが、音声のデコードのスレッドは
//  止めた位置の音を ring にため続けるので、同じ処理・ring に書くとぶつかる（閉じたあと、手元の動画の音もずれる）。
//  音響の設定・音量は、再生のエンジンの今の値を、処理の回ごとに写す（操作パネルの「音響」で変えると、YouTube の音にも効く）。
//

#if DEBUG
import CinemaAudio
import Foundation
import Synchronization
import TheaterMedia

nonisolated final class YouTubeSound: @unchecked Sendable {
    /// 1 回に書くサンプルの数（約 11 ms）
    static let blockFrames = 512
    /// ring にこれだけたまっていたら、書かずに待つ（途切れないよう、少し多めにためる。遅れは先の時刻の音を書いて打ち消す）
    static let bufferedFrames = 3_072
    /// 空間オーディオが音を出すまでの見込み（再生のエンジンの PlayerTiming.audioOutputLatency と同じ）
    static let outputLatency = 0.04
    /// 書く位置と動画の時計の差がこれを超えたら、合わせ直す（35 ms）
    static let resyncFrames = 1_680
    /// 鳴らし終えた音を、これだけ残して捨てる（サンプル）
    static let keptFrames = 10 * YouTubeAudioStore.sampleRate

    let ring: SpeakerFeedRing
    private let processor: CinemaProcessor
    /// 音響の設定・音量を写す元
    private let engine: MediaPlayer?
    private let store = YouTubeAudioStore()
    private let decoder: StreamAudioDecoder
    /// ページからの断片を、届いた順に処理する（base64 を解くのはメインスレッドの外で）
    private let inputQueue = DispatchQueue(label: "TheaterPlayer.YouTubeSound.input", qos: .userInitiated)
    /// setActive のたびに進める番号（古い鳴らすスレッドは抜ける）
    private let generation = Atomic<Int>(0)
    private let active = Atomic<Bool>(false)
    private let shared = Mutex(Shared())
    /// デコードの知らせ（デコードのスレッドが書く）
    private let decoderStatus = DecoderStatus()
    /// 鳴らすスレッドの 1 回分（入れ直したとき、古いスレッドと重ならないように）
    private let feedLock = NSLock()
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let feeds: [UnsafeMutablePointer<Float>]

    /// ページからの知らせと様子（どのスレッドからも withLock で触る）
    private struct Shared {
        var clock = YouTubeVideoClock()
        /// ページの音量（ミュートなら 0）
        var gain: Float = 1
        /// 利用者の調整（秒。正なら音を遅らせる）
        var audioDelay = 0.0
        /// 今の音声の入れ物の番号と、初期化の断片（読み直すときに使う）
        var sourceID = 0
        var initialization: (data: Data, offset: Double)?
        var report = Report()
        var offsetSum = 0.0
        var offsetCount = 0
        var jitterSum = 0.0
        var jitterCount = 0
        var missingFrames = 0
    }

    /// 鳴らすスレッドだけが持つ状態
    private struct FeederState {
        var writePosition: Int?
        var appliedGain: Float = 0
        var wasPlaying = false
        var started = false
    }

    /// speakers：空間オーディオの音源の系統の並び（再生のエンジンの ring と同じ順）
    init(engine: MediaPlayer?, speakers: [CinemaBus]) throws {
        self.engine = engine
        processor = try CinemaProcessor(speakers: speakers)
        ring = SpeakerFeedRing(feeds: speakers.count)
        left = .allocate(capacity: Self.blockFrames)
        right = .allocate(capacity: Self.blockFrames)
        feeds = (0..<speakers.count).map { _ in .allocate(capacity: Self.blockFrames) }
        left.initialize(repeating: 0, count: Self.blockFrames)
        right.initialize(repeating: 0, count: Self.blockFrames)
        feeds.forEach { $0.initialize(repeating: 0, count: Self.blockFrames) }
        let store = store
        let decoderStatus = decoderStatus
        decoder = StreamAudioDecoder { left, right, frames, time in
            store.insert(left: left, right: right, frames: frames, at: time)
        } status: { status in
            decoderStatus.value.withLock { $0 = status }
        }
        ring.setPaused(true)
    }

    deinit {
        decoder.stop()
        left.deallocate()
        right.deallocate()
        feeds.forEach { $0.deallocate() }
    }

    var isActive: Bool {
        active.load(ordering: .acquiring)
    }

    /// 利用者の調整（秒。正なら音を遅らせる）
    var audioDelay: Double {
        get { shared.withLock { $0.audioDelay } }
        set { shared.withLock { $0.audioDelay = newValue } }
    }

    /// 通し始める・やめる。通すあいだは、空間オーディオの音源がこの ring を鳴らす
    func setActive(_ value: Bool) {
        guard active.exchange(value, ordering: .acquiringAndReleasing) != value else {
            return
        }
        let current = generation.add(1, ordering: .acquiringAndReleasing).newValue
        inputQueue.async { [self] in
            decoder.stop()
            store.clear()
            shared.withLock { $0 = Shared(audioDelay: $0.audioDelay) }
            decoderStatus.value.withLock { $0 = nil }
        }
        guard value else {
            // やめたら、すぐに手元のファイルの音（止めてあるので無音）に戻す
            SpeakerRoute.shared.use(nil)
            return
        }
        ring.setPaused(true)
        ring.flush()
        SpeakerRoute.shared.use(ring)
        let thread = Thread { [self] in
            runFeeder(generation: current)
        }
        thread.name = "TheaterPlayer.YouTubeSound"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// 届いた知らせ・断片を処理し終えるまで待つ（テスト用）
    func waitForInput() {
        inputQueue.sync {}
    }

    // MARK: - ページからの知らせ

    /// ページのスクリプトからの知らせ（source・append・remove・abort・clock。メインスレッドから呼ぶ）
    func receive(_ message: [String: Any]) {
        guard isActive, let type = message["type"] as? String else {
            return
        }
        let id = (message["id"] as? NSNumber)?.intValue ?? 0
        switch type {
        case "clock":
            receiveClock(message)
        case "source":
            inputQueue.async { [self] in
                decoder.stop()
                store.clear()
                shared.withLock {
                    $0.sourceID = id
                    $0.initialization = nil
                }
                decoderStatus.value.withLock { $0 = nil }
            }
        case "append":
            guard let text = message["data"] as? String else {
                return
            }
            let isInitialization = (message["init"] as? NSNumber)?.boolValue ?? false
            let offset = (message["offset"] as? NSNumber)?.doubleValue ?? 0
            inputQueue.async { [self] in
                append(text, id: id, isInitialization: isInitialization, offset: offset)
            }
        case "remove":
            let start = (message["start"] as? NSNumber)?.doubleValue ?? 0
            let end = (message["end"] as? NSNumber)?.doubleValue ?? 0
            inputQueue.async { [self] in
                if shared.withLock({ $0.sourceID == id }) {
                    store.remove(from: start, to: end)
                }
            }
        case "abort":
            // ページが断片の読み込みをやめた：初期化の断片から読み直す
            inputQueue.async { [self] in
                if let initialization = shared.withLock({ $0.sourceID == id ? $0.initialization : nil }) {
                    decoder.start(initialization: initialization.data, timestampOffset: initialization.offset)
                }
            }
        default:
            break
        }
    }

    private func receiveClock(_ message: [String: Any]) {
        guard let time = (message["time"] as? NSNumber)?.doubleValue, let at = (message["at"] as? NSNumber)?.doubleValue else {
            return
        }
        let rate = (message["rate"] as? NSNumber)?.doubleValue ?? 1
        let playing = (message["playing"] as? NSNumber)?.boolValue ?? false
        let volume = (message["volume"] as? NSNumber)?.floatValue ?? 1
        shared.withLock {
            if let error = $0.clock.update(mediaTime: time, at: at / 1_000, rate: rate, playing: playing) {
                $0.jitterSum += abs(error)
                $0.jitterCount += 1
            }
            $0.gain = min(max(volume, 0), 1)
        }
    }

    private func append(_ text: String, id: Int, isInitialization: Bool, offset: Double) {
        guard shared.withLock({ $0.sourceID == id }), let data = Data(base64Encoded: text) else {
            return
        }
        shared.withLock {
            $0.report.appends += 1
            $0.report.bytes += data.count
            if isInitialization {
                $0.initialization = (data, offset)
            }
        }
        if isInitialization {
            decoder.start(initialization: data, timestampOffset: offset)
        } else {
            decoder.append(data, timestampOffset: offset)
        }
    }

    // MARK: - 鳴らす

    private func runFeeder(generation current: Int) {
        var state = FeederState()
        while generation.load(ordering: .acquiring) == current {
            guard ring.pendingFrames < Self.bufferedFrames else {
                if !state.started {
                    // 無音で bufferedFrames までためてから鳴らし始める（今書く音が聞こえるまでの見込みが、始めからそろう）
                    ring.setPaused(false)
                    state.started = true
                }
                Thread.sleep(forTimeInterval: 0.003)
                continue
            }
            feedLock.withLock {
                feed(&state)
            }
        }
    }

    /// 1 回分（blockFrames）を書く。動画を再生していれば、今書く音が聞こえる時刻の、動画の時刻の音
    private func feed(_ state: inout FeederState) {
        followEngine()
        let frames = Self.blockFrames
        let now = Date().timeIntervalSince1970
        let (clock, gain, delay) = shared.withLock { ($0.clock, $0.gain, $0.audioDelay) }
        let playing = state.started && clock.isPlaying && abs(clock.rate - 1) < 0.01
        if playing != state.wasPlaying {
            // 止めた：たまっている分を捨てて、すぐに止める（止めているあいだは無音でため直す）。動かした：合わせ直す
            if !playing {
                ring.flush()
            }
            state.writePosition = nil
            state.wasPlaying = playing
        }
        var targetGain: Float = 0
        if playing, let mediaNow = clock.mediaTime(at: now) {
            let lead = leadSeconds()
            let desired = YouTubeAudioStore.index(of: mediaNow + lead - delay)
            if let position = state.writePosition, abs(position - desired) <= Self.resyncFrames {
                record(offset: position - desired, lead: lead)
            } else {
                if state.writePosition != nil {
                    shared.withLock { $0.report.resyncs += 1 }
                }
                state.writePosition = desired
            }
            let position = state.writePosition ?? desired
            let found = store.read(at: position, frames: frames, left: left, right: right)
            state.writePosition = position + frames
            store.evict(before: position - Self.keptFrames)
            targetGain = gain
            shared.withLock { $0.missingFrames += frames - found }
        } else {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
        }
        applyGain(from: state.appliedGain, to: targetGain, frames: frames)
        state.appliedGain = targetGain
        processor.process(input: [UnsafePointer(left), UnsafePointer(right)], frames: frames, output: feeds)
        ring.write(feeds.map { UnsafePointer($0) }, frames: frames)
    }

    /// 今、音響処理に入れる音が聞こえるまで（秒）：ring の今の読み出しの位置から書く所までと、音響処理の遅れと、出力の遅れ
    private func leadSeconds() -> Double {
        let rate = Double(YouTubeAudioStore.sampleRate)
        let written = ring.writtenFrames + CinemaProcessor.latencyFrames
        // まだ読まれていない（鳴らし始めた直後）：たまっている分のあとに鳴る
        guard let render = ring.lastRender() else {
            return Double(ring.pendingFrames + CinemaProcessor.latencyFrames) / rate + Self.outputLatency
        }
        let sinceRender = HostTime.seconds(from: render.hostTime, to: mach_absolute_time())
        return Double(written - render.index) / rate - sinceRender + Self.outputLatency
    }

    private func record(offset: Int, lead: Double) {
        shared.withLock {
            $0.offsetSum += Double(offset)
            $0.offsetCount += 1
            $0.report.lead = lead * 1_000
        }
    }

    /// ページの音量を掛ける（変わったら、1 回の中でなめらかに移す）。ピークも数える
    private func applyGain(from start: Float, to end: Float, frames: Int) {
        let step = (end - start) / Float(frames)
        var peak: Float = 0
        for frame in 0..<frames {
            let gain = start + step * Float(frame + 1)
            left[frame] *= gain
            right[frame] *= gain
            peak = max(peak, abs(left[frame]), abs(right[frame]))
        }
        shared.withLock { $0.report.peak = max($0.report.peak, peak) }
    }

    /// 音響の設定・音量を、再生のエンジンの今の値にそろえる
    private func followEngine() {
        guard let engine else {
            return
        }
        processor.update(settings: engine.processor.latestSettings)
        processor.outputGain = engine.processor.outputGain
        ring.volume = engine.ring.volume
    }

    // MARK: - 様子

    /// 前に読んでからの様子
    func report() -> Report {
        let now = Date().timeIntervalSince1970
        let milliseconds = 1_000 / Double(YouTubeAudioStore.sampleRate)
        let (base, mediaNow) = shared.withLock { shared -> (Report, Double?) in
            var report = shared.report
            report.offset = shared.offsetCount > 0 ? shared.offsetSum / Double(shared.offsetCount) * milliseconds : 0
            report.clockJitter = shared.jitterCount > 0 ? shared.jitterSum / Double(shared.jitterCount) * 1_000 : 0
            report.missing = Double(shared.missingFrames) * milliseconds
            report.isPlaying = shared.clock.isPlaying && abs(shared.clock.rate - 1) < 0.01
            report.rate = shared.clock.rate
            shared.offsetSum = 0
            shared.offsetCount = 0
            shared.jitterSum = 0
            shared.jitterCount = 0
            shared.missingFrames = 0
            shared.report.peak = 0
            return (report, shared.clock.mediaTime(at: now))
        }
        var report = base
        report.readers = ring.readerSpread().readers
        switch decoderStatus.value.withLock({ $0 }) {
        case let .opened(format):
            report.format = format
        case let .failed(problem):
            report.problem = problem
        case nil:
            break
        }
        if let mediaNow {
            report.bufferedAhead = store.continuousSeconds(from: YouTubeAudioStore.index(of: mediaNow))
        }
        return report
    }
}

extension YouTubeSound {
    /// 様子（1 秒ごとに読む）
    struct Report: Equatable {
        /// デコードしている音声の形式（opus 48000 Hz 2 ch など）
        var format = ""
        /// 動画の再生の位置から先に、切れ目なく届いている音の長さ（秒）
        var bufferedAhead = 0.0
        /// 今書く音が聞こえるまでの見込み（ミリ秒。この分だけ先の時刻の音を書く）
        var lead = 0.0
        /// 書いている位置と、動画の時計から決まる位置の差の平均（ミリ秒。正なら音が先に進んでいる）
        var offset = 0.0
        /// 動画の時計の知らせの揺れ（予想との差の絶対値の平均、ミリ秒）
        var clockJitter = 0.0
        /// 合わせ直した回数（シーク・途切れのたび。通し）
        var resyncs = 0
        /// 鳴らすはずの所に音が無かった長さ（前に読んでから、ミリ秒）
        var missing = 0.0
        /// 受けた断片の数とバイト数（通し）
        var appends = 0
        var bytes = 0
        /// 書いた音のいちばん大きなサンプル（前に読んでから。0〜1）
        var peak: Float = 0
        /// YouTube の輪のバッファを、最近読んだ空間オーディオの音源の数
        var readers = 0
        /// 動画を再生している（速さは 1 倍）
        var isPlaying = false
        /// 動画の再生の速さ（1 倍以外のあいだは鳴らさない。ページの音のまま）
        var rate = 1.0
        /// デコードの知らせ（開けない・音声が無いなど）
        var problem = ""
    }
}

/// デコードの知らせを、YouTubeSound の作りかけ（init の中）から渡せるように包む
nonisolated private final class DecoderStatus: Sendable {
    let value = Mutex<StreamAudioDecoder.Status?>(nil)
}
#endif
