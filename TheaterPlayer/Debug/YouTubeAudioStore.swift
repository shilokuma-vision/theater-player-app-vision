//
//  YouTubeAudioStore.swift
//  TheaterPlayer
//
//  デバッグ用（デバッグのビルドだけ）：YouTube のページの MSE から写してデコードした音（48 kHz・ステレオ）を、動画の時刻ごとに持つ。
//  ページは再生の位置より先までの音を MSE に入れるので、その時刻の音を、映像に合わせて先に取り出せる。
//  位置はサンプルの番号（時刻 × 48,000）で数え、1 秒ごとの区画に入れる。同じ時刻に新しい音が届いたら、上書きする
//  （シークのあとに入れ直した・ページが一部を消した）。どこに音があるかは coverage で持つ。
//  デコードのスレッド（書く）と、鳴らすスレッド（読む）から使う。
//

#if DEBUG
import Foundation
import Synchronization

nonisolated final class YouTubeAudioStore: Sendable {
    static let sampleRate = 48_000

    private struct Contents {
        /// 1 秒ごとの区画（番号 → 左右のサンプル）
        var seconds: [Int: Second] = [:]
        /// 音のあるサンプルの番号
        var coverage = IndexSet()
        /// これより前の音は持たない（鳴らし終えた所）
        var floor = Int.min
    }

    private struct Second {
        var left = [Float](repeating: 0, count: YouTubeAudioStore.sampleRate)
        var right = [Float](repeating: 0, count: YouTubeAudioStore.sampleRate)
    }

    private let contents = Mutex(Contents())

    static func index(of time: Double) -> Int {
        Int((time * Double(sampleRate)).rounded())
    }

    /// 時刻 time（秒）から frames サンプルを入れる（その範囲にあった音は上書きする）
    func insert(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, at time: Double) {
        guard frames > 0, time.isFinite else {
            return
        }
        let start = Self.index(of: time)
        contents.withLock { contents in
            // 鳴らし終えた所（floor より前）は入れない
            var offset = contents.floor > start ? contents.floor - start : 0
            guard offset < frames else {
                return
            }
            contents.coverage.insert(integersIn: (start + offset)..<(start + frames))
            while offset < frames {
                let index = start + offset
                let (slot, position) = Self.slot(of: index)
                let count = min(frames - offset, Self.sampleRate - position)
                var second = contents.seconds.removeValue(forKey: slot) ?? Second()
                second.left.withUnsafeMutableBufferPointer { target in
                    (target.baseAddress! + position).update(from: left + offset, count: count)
                }
                second.right.withUnsafeMutableBufferPointer { target in
                    (target.baseAddress! + position).update(from: right + offset, count: count)
                }
                contents.seconds[slot] = second
                offset += count
            }
        }
    }

    /// サンプルの番号 index から frames サンプルを読む。音の無い所は無音。音のあったサンプルの数を返す
    @discardableResult
    func read(at index: Int, frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Int {
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        return contents.withLock { contents in
            var found = 0
            let wanted = IndexSet(integersIn: index..<(index + frames))
            for range in contents.coverage.intersection(wanted).rangeView {
                var current = range.lowerBound
                while current < range.upperBound {
                    let (slot, position) = Self.slot(of: current)
                    let count = min(range.upperBound - current, Self.sampleRate - position)
                    if let second = contents.seconds[slot] {
                        let offset = current - index
                        second.left.withUnsafeBufferPointer { (left + offset).update(from: $0.baseAddress! + position, count: count) }
                        second.right.withUnsafeBufferPointer { (right + offset).update(from: $0.baseAddress! + position, count: count) }
                        found += count
                    }
                    current += count
                }
            }
            return found
        }
    }

    /// 時刻 start〜end（秒）の音を消す（ページが MSE から消した）
    func remove(from start: Double, to end: Double) {
        guard start.isFinite, start < end else {
            return
        }
        let lower = Self.index(of: start)
        let upper = end.isFinite ? Self.index(of: end) : Int.max / 2
        contents.withLock { $0.coverage.remove(integersIn: lower..<max(lower, upper)) }
    }

    /// サンプルの番号 index より前の音を捨てる（鳴らし終えた）
    func evict(before index: Int) {
        contents.withLock { contents in
            contents.floor = max(contents.floor, index)
            guard let first = contents.coverage.first, first < index else {
                return
            }
            contents.coverage.remove(integersIn: first..<index)
            let (slot, _) = Self.slot(of: index)
            for key in contents.seconds.keys.filter({ $0 < slot }) {
                contents.seconds.removeValue(forKey: key)
            }
        }
    }

    /// サンプルの番号 index から、切れ目なく音のある長さ（秒）
    func continuousSeconds(from index: Int) -> Double {
        contents.withLock { contents in
            guard let range = contents.coverage.rangeView.first(where: { $0.contains(index) }) else {
                return 0
            }
            return Double(range.upperBound - index) / Double(Self.sampleRate)
        }
    }

    func clear() {
        contents.withLock { $0 = Contents() }
    }

    /// サンプルの番号の、1 秒の区画の番号と、区画の中の位置（負の番号も下へ丸める）
    private static func slot(of index: Int) -> (Int, Int) {
        let slot = index >= 0 ? index / sampleRate : -((-index - 1) / sampleRate) - 1
        return (slot, index - slot * sampleRate)
    }
}
#endif
