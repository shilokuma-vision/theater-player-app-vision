//
//  SpeakerFeedRing.swift
//  CinemaAudio
//
//  スピーカーごとの信号を、RealityKit の空間オーディオ（音源ごとの AudioGeneratorController）へ渡す輪のバッファ。
//  書き手は 1 つ（音声のデコードのスレッド）、読み手はスピーカーの数だけ（オーディオのリアルタイムのスレッド）。
//
//  すべてのスピーカーの音をサンプル単位でそろえるため、読み出す位置を各読み手が自分で数えず、
//  描画の時刻（AudioTimeStamp の mSampleTime）から決める：位置 = 基準の位置 + (mSampleTime - 基準の mSampleTime)。
//  同じ描画の回の読み手は同じ mSampleTime を受け取るので、同じ範囲を読む。
//  データが足りないとき（デコードが追いつかない・再生の始め）は無音を出し、次の回から、書けている所に基準を合わせ直す。
//  描画の時刻が戻った・大きく飛んだとき（オーディオのエンジンの再起動など）は、続きの位置に基準を合わせ直す。
//
//  読み終えた位置（consumed）は、描画の回が変わったときに、その回の頭まで進める（どの読み手でもよい）。
//  回の終わりまで進めると、同じ回のまだ読んでいないスピーカーの範囲を書き手が上書きしてしまう。
//

import Foundation
import Synchronization

public final class SpeakerFeedRing: @unchecked Sendable {
    public let feeds: Int
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    /// 書いたサンプルの数（書き手だけが増やす）
    private let written = Atomic<Int>(0)
    /// 読んだ位置（いまの描画の回の頭。書き手は、ここより capacity 先までしか書かない）
    private let consumed = Atomic<Int>(0)
    private let timeline = Mutex(Timeline())
    private let volumeBits = Atomic<UInt32>(Float(1).bitPattern)

    private struct Timeline {
        var paused = true
        /// 基準（mSampleTime と、そのときの読み出しの位置）
        var anchorSampleTime: Double?
        var anchorIndex = 0
        /// 次の回で、この位置に基準を合わせ直す
        var reanchorIndex: Int?
        /// いちばん新しい描画の回（時計に使う）
        var lastSampleTime: Double = -1
        var lastIndex = 0
        var lastHostTime: UInt64 = 0
        var lastFrames = 0
    }

    public init(feeds: Int, capacity: Int = 32_768) {
        self.feeds = feeds
        self.capacity = capacity
        storage = .allocate(capacity: feeds * capacity)
        storage.initialize(repeating: 0, count: feeds * capacity)
    }

    deinit {
        storage.deallocate()
    }

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

    /// 書いた物を捨て、通しの番号を from からにする（シークのとき）。読み手は無音になり、次に書いた所から鳴らす
    public func flush() {
        timeline.withLock { line in
            let now = written.load(ordering: .acquiring)
            line.anchorSampleTime = nil
            line.reanchorIndex = nil
            consumed.store(now, ordering: .releasing)
        }
    }

    // MARK: - 再生の制御

    public func setPaused(_ paused: Bool) {
        timeline.withLock { line in
            line.paused = paused
            if paused {
                line.anchorSampleTime = nil
            }
        }
    }

    /// 音量（0〜）。描画の回ごとに、前の音量からなめらかに変える
    public var volume: Float {
        get { Float(bitPattern: volumeBits.load(ordering: .relaxed)) }
        set { volumeBits.store(max(0, newValue).bitPattern, ordering: .relaxed) }
    }

    /// 時計：いちばん新しい描画の回の、ホストの時刻と読み出しの位置（通しの番号）。まだ鳴っていなければ nil
    public func lastRender() -> (hostTime: UInt64, index: Int)? {
        timeline.withLock { line in
            line.lastSampleTime < 0 || line.paused ? nil : (line.lastHostTime, line.lastIndex)
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
        guard let start = readStart(feed: feed, frames: frames, sampleTime: time.sampleTime, hostTime: time.hostTime) else {
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
    private func readStart(feed: Int, frames: Int, sampleTime: Double, hostTime: UInt64) -> Int? {
        let available = written.load(ordering: .acquiring)
        return timeline.withLock { line in
            guard !line.paused else {
                return nil
            }
            let newCycle = sampleTime != line.lastSampleTime
            if newCycle, line.anchorSampleTime != nil, line.lastSampleTime >= 0, line.reanchorIndex == nil,
               sampleTime < line.lastSampleTime || sampleTime - line.lastSampleTime > Double(capacity) {
                // 時刻が戻った・大きく飛んだ：前の回の続きから鳴らす
                line.reanchorIndex = line.lastIndex + line.lastFrames
            }
            if line.anchorSampleTime == nil || (line.reanchorIndex != nil && newCycle) {
                let index = line.reanchorIndex ?? consumed.load(ordering: .acquiring)
                line.anchorSampleTime = sampleTime
                line.anchorIndex = min(max(index, available - capacity, 0), available)
                line.reanchorIndex = nil
            }
            let start = line.anchorIndex + Int((sampleTime - (line.anchorSampleTime ?? sampleTime)).rounded())
            if newCycle {
                line.lastSampleTime = sampleTime
                line.lastIndex = start
                line.lastHostTime = hostTime
                line.lastFrames = frames
                // 前の回までは鳴らし終えた。この回の範囲（start から）は、残りのスピーカーが読むまで書き手に渡さない
                let done = min(start, available)
                if done > consumed.load(ordering: .relaxed) {
                    consumed.store(done, ordering: .releasing)
                }
            }
            // 足りない：無音を出し、次の回から、書けている所の終わりに基準を合わせ直す（同じ所をくり返さない）
            if start + frames > available, line.reanchorIndex == nil {
                line.reanchorIndex = available
            }
            return start
        }
    }
}
