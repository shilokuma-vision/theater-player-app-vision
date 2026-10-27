//
//  SpeakerFeedRingTests.swift
//  CinemaAudioTests
//

@testable import CinemaAudio
import Testing

struct SpeakerFeedRingTests {
    func write(_ ring: SpeakerFeedRing, values: [Float]) {
        let copies = (0..<ring.feeds).map { feed in values.map { $0 + Float(feed) * 1_000 } }
        copies[0].withUnsafeBufferPointer { first in
            copies[1].withUnsafeBufferPointer { second in
                ring.write([first.baseAddress!, second.baseAddress!], frames: values.count)
            }
        }
    }

    func read(_ ring: SpeakerFeedRing, feed: Int, frames: Int, sampleTime: Double, gain: inout Float) -> [Float] {
        var out = [Float](repeating: -1, count: frames)
        out.withUnsafeMutableBufferPointer { pointer in
            ring.read(
                feed: feed,
                into: pointer.baseAddress!,
                frames: frames,
                time: RenderTime(sampleTime: sampleTime, hostTime: 0),
                previousGain: &gain
            )
        }
        return out
    }

    @Test func readersInTheSameCycleReadTheSameRange() {
        let ring = SpeakerFeedRing(feeds: 2, capacity: 64)
        write(ring, values: (0..<32).map(Float.init))
        ring.setPaused(false)
        var gains: [Float] = [1, 1]
        let first = read(ring, feed: 0, frames: 8, sampleTime: 500, gain: &gains[0])
        let second = read(ring, feed: 1, frames: 8, sampleTime: 500, gain: &gains[1])
        #expect(first == (0..<8).map(Float.init))
        #expect(second == (0..<8).map { Float($0) + 1_000 })
        let next = read(ring, feed: 1, frames: 8, sampleTime: 508, gain: &gains[1])
        #expect(next == (8..<16).map { Float($0) + 1_000 })
    }

    /// 書き手が輪を満杯に保っていても、同じ描画の回のあとの読み手が読む範囲は上書きされない
    @Test func writerDoesNotOverwriteTheCycleBeingRead() {
        let ring = SpeakerFeedRing(feeds: 2, capacity: 16)
        write(ring, values: (0..<16).map(Float.init))
        ring.setPaused(false)
        var gains: [Float] = [1, 1]
        _ = read(ring, feed: 0, frames: 8, sampleTime: 100, gain: &gains[0])
        write(ring, values: (16..<24).map(Float.init))
        let second = read(ring, feed: 1, frames: 8, sampleTime: 100, gain: &gains[1])
        #expect(second == (0..<8).map { Float($0) + 1_000 })
        // 次の回になれば、前の回の分は書き手に渡る
        _ = read(ring, feed: 1, frames: 8, sampleTime: 108, gain: &gains[1])
        #expect(ring.writableFrames == 8)
    }

    /// 描画の時刻が戻ったら（オーディオのエンジンの再起動など）、前の回の続きから鳴らす
    @Test func sampleTimeGoingBackResumesFromTheLastPosition() {
        let ring = SpeakerFeedRing(feeds: 2, capacity: 64)
        write(ring, values: (0..<32).map(Float.init))
        ring.setPaused(false)
        var gain: Float = 1
        _ = read(ring, feed: 0, frames: 8, sampleTime: 1_000, gain: &gain)
        _ = read(ring, feed: 0, frames: 8, sampleTime: 1_008, gain: &gain)
        let restarted = read(ring, feed: 0, frames: 8, sampleTime: 0, gain: &gain)
        #expect(restarted == (16..<24).map(Float.init))
    }

    @Test func underrunPlaysSilenceAndResumesWhereTheDataEnds() {
        let ring = SpeakerFeedRing(feeds: 2, capacity: 64)
        write(ring, values: (0..<4).map(Float.init))
        ring.setPaused(false)
        var gain: Float = 1
        let partial = read(ring, feed: 0, frames: 8, sampleTime: 0, gain: &gain)
        #expect(Array(partial.prefix(4)) == [0, 1, 2, 3])
        #expect(Array(partial.suffix(4)) == [0, 0, 0, 0])
        write(ring, values: (4..<12).map(Float.init))
        let resumed = read(ring, feed: 0, frames: 8, sampleTime: 8, gain: &gain)
        #expect(resumed == (4..<12).map(Float.init))
    }

    @Test func pausedRingIsSilentAndWriterStopsWhenFull() {
        let ring = SpeakerFeedRing(feeds: 2, capacity: 16)
        write(ring, values: (0..<20).map(Float.init))
        #expect(ring.writtenFrames == 16)
        var gain: Float = 1
        #expect(read(ring, feed: 0, frames: 4, sampleTime: 0, gain: &gain) == [0, 0, 0, 0])
    }
}
