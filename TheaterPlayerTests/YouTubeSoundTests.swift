//
//  YouTubeSoundTests.swift
//  TheaterPlayerTests
//
//  デバッグ用の YouTube（デバッグのビルドだけ）の「映画館の音響に通す」：デコードした音を動画の時刻ごとに持つ入れ物、
//  ページの <video> の時計、ページの元の音を消すか・空間オーディオを鳴らし直すかの決め方、空間オーディオの音源が読む輪のバッファの切り替え
//

#if DEBUG
import AVFAudio
import CinemaAudio
import Foundation
import Testing
@testable import TheaterPlayer

struct YouTubeSoundTests {
    // MARK: - 入れ物

    func insert(_ store: YouTubeAudioStore, values: [Float], at time: Double) {
        let negated = values.map { -$0 }
        values.withUnsafeBufferPointer { left in
            negated.withUnsafeBufferPointer { right in
                store.insert(left: left.baseAddress!, right: right.baseAddress!, frames: values.count, at: time)
            }
        }
    }

    /// 読んだ音（左右と、音のあったサンプルの数）
    struct Read {
        var left: [Float]
        var right: [Float]
        var found: Int
    }

    func read(_ store: YouTubeAudioStore, at index: Int, frames: Int) -> Read {
        var left = [Float](repeating: -9, count: frames)
        var right = [Float](repeating: -9, count: frames)
        let found = left.withUnsafeMutableBufferPointer { leftPointer in
            right.withUnsafeMutableBufferPointer { rightPointer in
                store.read(at: index, frames: frames, left: leftPointer.baseAddress!, right: rightPointer.baseAddress!)
            }
        }
        return Read(left: left, right: right, found: found)
    }

    /// 入れた時刻の音を読める。1 秒の区画をまたいでも続く。音の無い所は無音
    @Test
    func storeReadsByMediaTime() {
        let store = YouTubeAudioStore()
        // 0.99 秒から 960 サンプル（1 秒の区画をまたぐ）
        let values = (0..<960).map { Float($0) / 1_000 }
        insert(store, values: values, at: 0.99)
        let start = YouTubeAudioStore.index(of: 0.99)
        let all = read(store, at: start, frames: 960)
        #expect(all.found == 960)
        #expect(all.left == values)
        #expect(all.right == values.map { -$0 })
        // 前後にはみ出した所は無音
        let around = read(store, at: start - 10, frames: 20)
        #expect(around.found == 10)
        #expect(around.left.prefix(10).allSatisfy { $0 == 0 })
        #expect(Array(around.left.suffix(10)) == Array(values.prefix(10)))
        #expect(abs(store.continuousSeconds(from: start) - 0.02) < 0.000_1)
    }

    /// 同じ時刻に新しい音が届いたら上書きする。ページが消した範囲は無音になる
    @Test
    func storeOverwritesAndRemoves() {
        let store = YouTubeAudioStore()
        insert(store, values: [Float](repeating: 0.1, count: 4_800), at: 2)
        insert(store, values: [Float](repeating: 0.5, count: 480), at: 2.05)
        let start = YouTubeAudioStore.index(of: 2)
        let mixed = read(store, at: start, frames: 4_800)
        #expect(mixed.found == 4_800)
        #expect(mixed.left[2_399] == 0.1)
        #expect(mixed.left[2_400] == 0.5)
        #expect(mixed.left[2_880] == 0.1)
        store.remove(from: 2.0, to: 2.05)
        let removed = read(store, at: start, frames: 4_800)
        #expect(removed.found == 2_400)
        #expect(removed.left[0] == 0)
        #expect(removed.left[2_400] == 0.5)
    }

    /// 鳴らし終えた所は捨て、そこより前に届いた音は入れない
    @Test
    func storeEvictsPlayedSound() {
        let store = YouTubeAudioStore()
        insert(store, values: [Float](repeating: 0.2, count: 96_000), at: 0)
        store.evict(before: 48_000)
        #expect(read(store, at: 0, frames: 48_000).found == 0)
        #expect(read(store, at: 48_000, frames: 48_000).found == 48_000)
        insert(store, values: [Float](repeating: 0.3, count: 4_800), at: 0.5)
        #expect(read(store, at: 24_000, frames: 4_800).found == 0)
        store.clear()
        #expect(read(store, at: 48_000, frames: 10).found == 0)
    }

    // MARK: - 動画の時計

    /// 再生中は、知らせを受けた時刻から速さで進める。止めているあいだは進まない
    @Test
    func clockAdvancesWhilePlaying() throws {
        var clock = YouTubeVideoClock()
        #expect(clock.mediaTime(at: 100) == nil)
        clock.update(mediaTime: 10, at: 100, rate: 1, playing: true)
        #expect(try #require(clock.mediaTime(at: 100.5)) == 10.5)
        clock.update(mediaTime: 12, at: 102, rate: 2, playing: true)
        #expect(try #require(clock.mediaTime(at: 103)) == 14)
        clock.update(mediaTime: 20, at: 110, rate: 1, playing: false)
        #expect(try #require(clock.mediaTime(at: 200)) == 20)
    }

    /// 予想との小さな差は少しだけ寄せ（鳴らす位置が揺れない）、大きな差（シーク）はそのまま合わせ直す
    @Test
    func clockSmoothsSmallErrors() throws {
        var clock = YouTubeVideoClock()
        clock.update(mediaTime: 10, at: 100, rate: 1, playing: true)
        let reported = clock.update(mediaTime: 11.01, at: 101, rate: 1, playing: true)
        let error = try #require(reported)
        #expect(abs(error - 0.01) < 0.000_1)
        let smoothed = try #require(clock.mediaTime(at: 101))
        #expect(abs(smoothed - (11 + 0.01 * YouTubeVideoClock.smoothing)) < 0.000_1)
        let seek = clock.update(mediaTime: 40, at: 102, rate: 1, playing: true)
        #expect(seek == nil)
        #expect(try #require(clock.mediaTime(at: 102)) == 40)
    }

    // MARK: - ページの元の音を消すか・鳴らし直すか

    /// 空間オーディオが描画していて、音声を読めているときだけ、ページの元の音を消す
    @Test
    func guardMutesOnlyWhileTheaterSoundWorks() {
        var guardState = YouTubeSoundGuard()
        #expect(guardState.update(rendering: true, decoding: false) == .none)
        #expect(!guardState.mutesOriginal)
        #expect(guardState.update(rendering: true, decoding: true) == .none)
        #expect(guardState.mutesOriginal)
        // 読めなくなったら、すぐにページの音に戻す
        #expect(guardState.update(rendering: true, decoding: false) == .none)
        #expect(!guardState.mutesOriginal)
    }

    /// 描画が止まったら鳴らし直す。消したあとに止まっても、鳴らし直すあいだは消したまま。上限まで止まったままなら、ページの音に戻す
    @Test
    func guardHealsThenGivesUp() {
        var guardState = YouTubeSoundGuard()
        _ = guardState.update(rendering: true, decoding: true)
        #expect(guardState.mutesOriginal)
        var heals: [YouTubeSoundGuard.Action] = []
        for _ in 0..<(YouTubeSoundGuard.silentLimit * (YouTubeSoundGuard.maxHeals + 1)) {
            let action = guardState.update(rendering: false, decoding: true)
            if action != .none {
                heals.append(action)
            }
            if !guardState.gaveUp {
                #expect(guardState.mutesOriginal)
            }
        }
        #expect(heals == (1...YouTubeSoundGuard.maxHeals).map { .heal(attempt: $0) })
        #expect(guardState.gaveUp)
        #expect(!guardState.mutesOriginal)
        // あきらめたら、描画が戻っても消さない（スイッチを入れ直すまで）
        #expect(guardState.update(rendering: true, decoding: true) == .none)
        #expect(!guardState.mutesOriginal)
    }

    /// 消す前から描画が止まっていても（音声のセッションが有効でないなど）鳴らし直し、戻ったら消す
    @Test
    func guardHealsBeforeMuting() {
        var guardState = YouTubeSoundGuard()
        #expect(guardState.update(rendering: false, decoding: true) == .none)
        #expect(guardState.update(rendering: false, decoding: true) == .heal(attempt: 1))
        #expect(!guardState.mutesOriginal)
        #expect(guardState.update(rendering: true, decoding: true) == .none)
        #expect(guardState.mutesOriginal)
        #expect(guardState.silentSeconds == 0)
    }

    // MARK: - 音源の切り替え

    /// 描画の関数を 1 回呼んで、出力の最後のサンプルを返す
    func render(_ block: AVAudioSourceNodeRenderBlock, frames: Int, sampleTime: Double) -> Float {
        var samples = [Float](repeating: -1, count: frames)
        return samples.withUnsafeMutableBufferPointer { pointer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: pointer.baseAddress)
            )
            var stamp = AudioTimeStamp()
            stamp.mSampleTime = sampleTime
            stamp.mHostTime = mach_absolute_time()
            stamp.mFlags = [.sampleTimeValid, .hostTimeValid]
            var silence = ObjCBool(false)
            _ = block(&silence, &stamp, AVAudioFrameCount(frames), &list)
            return pointer[frames - 1]
        }
    }

    func filledRing(value: Float) -> SpeakerFeedRing {
        let ring = SpeakerFeedRing(feeds: 1, capacity: 1_024)
        let values = [Float](repeating: value, count: 1_024)
        _ = values.withUnsafeBufferPointer { ring.write([$0.baseAddress!], frames: 1_024) }
        ring.setPaused(false)
        return ring
    }

    /// 代わりの輪のバッファを渡すと、そちらを鳴らす。外すと、再生のエンジンの物に戻る
    @Test
    func routeSwitchesBetweenRings() {
        let route = SpeakerRoute()
        let main = filledRing(value: 0.5)
        let replacement = filledRing(value: 0.25)
        let block = route.renderBlock(feed: 0, main: main)
        #expect(render(block, frames: 64, sampleTime: 0) == 0.5)
        route.use(replacement)
        #expect(render(block, frames: 64, sampleTime: 64) == 0.25)
        route.use(nil)
        #expect(render(block, frames: 64, sampleTime: 128) == 0.5)
    }
}
#endif
