//
//  SpeakerFeedRing.swift
//  CinemaAudio
//
//  スピーカーごとの信号を、RealityKit の空間オーディオ（音源ごとの AudioGeneratorController）へ渡す輪のバッファ。
//  書き手は 1 つ（音声のデコードのスレッド）、読み手はスピーカーの数だけ（オーディオのリアルタイムのスレッド）。
//
//  読み出す位置は、スピーカーごとに自分の描画の時刻（AudioTimeStamp の mSampleTime）で数える：
//  位置 = そのスピーカーの基準の位置 + (mSampleTime - そのスピーカーの基準の mSampleTime)。
//  mSampleTime の起点は音源ごとに違うことがあるので（実機で確かめた）、スピーカーどうしは、全員に共通の
//  ホストの時刻（mHostTime）でそろえる：基準を決めるとき、全体の基準（ホストの時刻と位置）からの経過で位置を決める。
//  データが足りないとき（デコードが追いつかない・再生の始め）は無音を出し、次から全員の基準を、書けている所の終わりに合わせ直す。
//  あるスピーカーの描画の時刻が戻った・大きく飛んだとき（オーディオのエンジンの再起動など）は、そのスピーカーだけ合わせ直す。
//
//  読み終えた位置（consumed）は、最近読んだスピーカーのうち、いちばん遅れている読み出しの頭まで進める。
//  それより先まで進めると、まだ読んでいないスピーカーの範囲を書き手が上書きしてしまう。
//

import Foundation
import Synchronization

public final class SpeakerFeedRing: @unchecked Sendable {
    public let feeds: Int
    public let capacity: Int
    public let sampleRate: Double
    private let storage: UnsafeMutablePointer<Float>
    /// 書いたサンプルの数（書き手だけが増やす）
    private let written = Atomic<Int>(0)
    /// 読んだ位置（最近読んだスピーカーのうち、いちばん遅れている読み出しの頭。書き手は、ここより capacity 先までしか書かない）
    private let consumed = Atomic<Int>(0)
    private let timeline: Mutex<Timeline>
    private let volumeBits = Atomic<UInt32>(Float(1).bitPattern)
    /// これより長く読まれていないスピーカーは、consumed を決めるときに数えない（ホストの時刻の単位）
    private let staleTicks: Int64

    /// スピーカーごとの読み出しの状態
    private struct Feed {
        /// 基準（このスピーカーの mSampleTime と、そのときの読み出しの位置）。nan なら次に読むときに決める
        var anchorSampleTime = Double.nan
        var anchorIndex = 0
        var lastSampleTime = -1.0
        var lastStart = 0
        var lastHost: UInt64 = 0
        var hasRead = false
    }

    private struct Clock {
        let host: UInt64
        let index: Int
    }

    private struct Timeline {
        var paused = true
        var feeds: [Feed]
        /// 全体の基準（ホストの時刻と、そのときの読み出しの位置）。nil なら次に読んだスピーカーが決める
        var clock: Clock?
        /// 次に読むときに、全員の基準をこの位置に合わせ直す（足りなかったとき）
        var reanchorIndex: Int?
        /// いちばん新しい読み出し（時計に使う）
        var lastIndex = 0
        var lastHost: UInt64 = 0
        var hasRendered = false

        mutating func resetAnchors() {
            for index in feeds.indices {
                feeds[index].anchorSampleTime = .nan
            }
            clock = nil
        }
    }

    public init(feeds: Int, capacity: Int = 32_768, sampleRate: Double = 48_000) {
        self.feeds = feeds
        self.capacity = capacity
        self.sampleRate = sampleRate
        storage = .allocate(capacity: feeds * capacity)
        storage.initialize(repeating: 0, count: feeds * capacity)
        timeline = Mutex(Timeline(feeds: [Feed](repeating: Feed(), count: feeds)))
        staleTicks = Int64(0.2 / Self.hostTickSeconds)
    }

    deinit {
        storage.deallocate()
    }

    /// ホストの時刻（mach_absolute_time）の 1 単位の秒数
    static let hostTickSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    // MARK: - 書き手

    /// 今すぐ書ける量
    public var writableFrames: Int {
        capacity - (written.load(ordering: .acquiring) - consumed.load(ordering: .acquiring))
    }

    /// 書いたサンプルの数（輪の中の位置ではなく、通しの番号）
    public var writtenFrames: Int {
        written.load(ordering: .acquiring)
    }

    /// 書いてまだ鳴らしていないサンプルの数
    public var pendingFrames: Int {
        written.load(ordering: .acquiring) - consumed.load(ordering: .acquiring)
    }

    /// feeds 本の信号を frames サンプル書く。書けた数を返す
    @discardableResult
    public func write(_ sources: [UnsafePointer<Float>], frames: Int) -> Int {
        let count = min(frames, writableFrames)
        guard count > 0 else {
            return 0
        }
        let start = written.load(ordering: .relaxed)
        for feed in 0..<min(feeds, sources.count) {
            let base = storage + feed * capacity
            for frame in 0..<count {
                base[(start + frame) % capacity] = sources[feed][frame]
            }
        }
        written.store(start + count, ordering: .releasing)
        return count
    }

    /// 書いた物を捨てる（シークのとき）。読み手は無音になり、次に書いた所から鳴らす
    public func flush() {
        timeline.withLock { line in
            let now = written.load(ordering: .acquiring)
            line.resetAnchors()
            line.reanchorIndex = nil
            for index in line.feeds.indices {
                line.feeds[index].hasRead = false
            }
            consumed.store(now, ordering: .releasing)
        }
    }

    // MARK: - 再生の制御

    public func setPaused(_ paused: Bool) {
        timeline.withLock { line in
            line.paused = paused
            if paused {
                line.resetAnchors()
            }
        }
    }

    /// 音量（0〜）。描画の回ごとに、前の音量からなめらかに変える
    public var volume: Float {
        get { Float(bitPattern: volumeBits.load(ordering: .relaxed)) }
        set { volumeBits.store(max(0, newValue).bitPattern, ordering: .relaxed) }
    }

    /// 時計：いちばん新しい読み出しの、ホストの時刻と読み出しの位置（通しの番号）。まだ鳴っていなければ nil
    public func lastRender() -> (hostTime: UInt64, index: Int)? {
        timeline.withLock { line in
            !line.hasRendered || line.paused ? nil : (line.lastHost, line.lastIndex)
        }
    }

    /// 診断用：最近読んだスピーカーの数と、その mSampleTime・ホストの時刻（秒）のばらつき（最大 − 最小）
    public struct ReaderSpread: Sendable {
        public let readers: Int
        public let sampleTime: Double
        public let host: Double
    }

    public func readerSpread() -> ReaderSpread {
        timeline.withLock { line in
            let recent = line.feeds.filter { $0.hasRead }
            guard let first = recent.first else {
                return ReaderSpread(readers: 0, sampleTime: 0, host: 0)
            }
            let samples = recent.map(\.lastSampleTime)
            let hosts = recent.map(\.lastHost)
            let hostSpread = Double((hosts.max() ?? first.lastHost) - (hosts.min() ?? first.lastHost)) * Self.hostTickSeconds
            return ReaderSpread(readers: recent.count, sampleTime: (samples.max() ?? 0) - (samples.min() ?? 0), host: hostSpread)
        }
    }
}

// MARK: - 読み手（リアルタイムのスレッド）

/// 描画の時刻。sampleTime は AudioTimeStamp の mSampleTime、hostTime はそのホストの時刻
public struct RenderTime: Sendable {
    public var sampleTime: Double
    public var hostTime: UInt64

    public init(sampleTime: Double, hostTime: UInt64) {
        self.sampleTime = sampleTime
        self.hostTime = hostTime
    }
}

extension SpeakerFeedRing {
    /// feed 番目の信号を frames サンプル読む。time は描画の時刻（AudioTimeStamp の mSampleTime と、そのホストの時刻）。
    /// previousGain はこの読み手が前に掛けた音量（なめらかに変えるため。呼び出し側が持つ）
    public func read(
        feed: Int,
        into output: UnsafeMutablePointer<Float>,
        frames: Int,
        time: RenderTime,
        previousGain: inout Float
    ) {
        guard feed < feeds, let start = readStart(feed: feed, frames: frames, time: time) else {
            output.update(repeating: 0, count: frames)
            previousGain = 0
            return
        }
        let available = written.load(ordering: .acquiring)
        let oldest = max(0, available - capacity)
        let base = storage + feed * capacity
        let target = volume
        let step = (target - previousGain) / Float(max(frames, 1))
        var gain = previousGain
        for frame in 0..<frames {
            let index = start + frame
            gain += step
            output[frame] = index < available && index >= oldest ? base[index % capacity] * gain : 0
        }
        previousGain = target
    }

    /// 読み出しの始まりの位置（鳴らさないときは nil）
    private func readStart(feed: Int, frames: Int, time: RenderTime) -> Int? {
        let available = written.load(ordering: .acquiring)
        return timeline.withLock { line in
            guard !line.paused else {
                return nil
            }
            // 足りなかった：全員の基準を、書けている所の終わりに合わせ直す
            if let index = line.reanchorIndex {
                line.resetAnchors()
                line.clock = Clock(host: time.hostTime, index: index)
                line.reanchorIndex = nil
            }
            var state = line.feeds[feed]
            // このスピーカーの描画の時刻が戻った・大きく飛んだ：このスピーカーだけ合わせ直す
            if !state.anchorSampleTime.isNaN,
               time.sampleTime < state.lastSampleTime || time.sampleTime - state.lastSampleTime > Double(capacity) {
                state.anchorSampleTime = .nan
            }
            if state.anchorSampleTime.isNaN {
                state.anchorSampleTime = time.sampleTime
                state.anchorIndex = min(max(anchorIndex(line: &line, hostTime: time.hostTime), available - capacity, 0), available)
            }
            let start = state.anchorIndex + Int((time.sampleTime - state.anchorSampleTime).rounded())
            state.lastSampleTime = time.sampleTime
            state.lastStart = start
            state.lastHost = time.hostTime
            state.hasRead = true
            line.feeds[feed] = state
            if !line.hasRendered || time.hostTime >= line.lastHost {
                line.lastHost = time.hostTime
                line.lastIndex = start
                line.hasRendered = true
            }
            // 足りない：無音を出し、次から合わせ直す（同じ所をくり返さない）
            if start + frames > available, line.reanchorIndex == nil {
                line.reanchorIndex = available
            }
            advanceConsumed(line: line, hostTime: time.hostTime, available: available)
            return start
        }
    }

    /// 基準を決めるスピーカーの読み出しの位置：全体の基準から、ホストの時刻の経過で決める（無ければ、ここを全体の基準にする）
    private func anchorIndex(line: inout Timeline, hostTime: UInt64) -> Int {
        guard let clock = line.clock else {
            let index = consumed.load(ordering: .acquiring)
            line.clock = Clock(host: hostTime, index: index)
            return index
        }
        let ticks = Int64(bitPattern: hostTime &- clock.host)
        return clock.index + Int((Double(ticks) * Self.hostTickSeconds * sampleRate).rounded())
    }

    /// 最近読んだスピーカーのうち、いちばん遅れている読み出しの頭まで、書き手に渡す
    private func advanceConsumed(line: Timeline, hostTime: UInt64, available: Int) {
        var slowest = Int.max
        for state in line.feeds where state.hasRead && Int64(bitPattern: hostTime &- state.lastHost) < staleTicks {
            slowest = min(slowest, state.lastStart)
        }
        let done = min(slowest, available)
        if done != Int.max, done > consumed.load(ordering: .relaxed) {
            consumed.store(done, ordering: .releasing)
        }
    }
}
