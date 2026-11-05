//
//  StreamAudioDecoderTests.swift
//  TheaterMediaTests
//
//  デバッグ用（デバッグのビルドだけ）の StreamAudioDecoder：少しずつ届く断片をつなげて読み、48 kHz・ステレオにする。
//  YouTube の MSE の WebM・MP4 の代わりに、AudioToolbox の AAC のエンコーダーで作った ADTS（44.1 kHz・ステレオ・1 kHz の正弦波）を、
//  細かく分けて渡す。ADTS はパケットに時刻が無いので、時刻の無いフレームを前のフレームの続きとして扱うかも確かめられる。
//  （Fixtures の AC-3 は CRC が合わず形式の見分けがあいまいで、中身だけからは別の形式と見なされることがある）
//

#if DEBUG
import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import TheaterMedia

struct StreamAudioDecoderTests {
    /// デコードした音の 1 回分
    struct Block {
        var time: Double
        var frames: Int
        var peak: Float
    }

    /// デコードした音（デコードのスレッドから書く）
    final class Collected: Sendable {
        let blocks = Mutex<[Block]>([])
        let statuses = Mutex<[StreamAudioDecoder.Status]>([])

        var frames: Int {
            blocks.withLock { $0.reduce(0) { $0 + $1.frames } }
        }

        func makeDecoder() -> StreamAudioDecoder {
            StreamAudioDecoder { [self] left, right, frames, time in
                var peak: Float = 0
                for frame in 0..<frames {
                    peak = max(peak, abs(left[frame]), abs(right[frame]))
                }
                blocks.withLock { $0.append(Block(time: time, frames: frames, peak: peak)) }
            } status: { [self] status in
                statuses.withLock { $0.append(status) }
            }
        }

        /// frames サンプル以上たまるまで待つ（最大 5 秒）
        func wait(for frames: Int) async {
            for _ in 0..<500 where self.frames < frames {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// AAC（ADTS）の流れ：44.1 kHz・ステレオ・振幅 0.25 の 1 kHz を seconds 秒
    static func makeADTS(seconds: Double) throws -> Data {
        let rate = 44_100.0
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        var description = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1_024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        let output = try #require(AVAudioFormat(streamDescription: &description))
        let converter = try #require(AVAudioConverter(from: input, to: output))
        let count = AVAudioFrameCount(seconds * rate)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: count))
        pcm.frameLength = count
        for channel in 0..<2 {
            let samples = try #require(pcm.floatChannelData?[channel])
            for frame in 0..<Int(count) {
                samples[frame] = 0.25 * sin(2 * .pi * 1_000 * Float(frame) / Float(rate))
            }
        }
        var data = Data()
        var fed = false
        while true {
            let packets = AVAudioCompressedBuffer(format: output, packetCapacity: 16, maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: packets, error: &error) { _, inputStatus in
                if fed {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                inputStatus.pointee = .haveData
                return pcm
            }
            for index in 0..<Int(packets.packetCount) {
                let packet = try #require(packets.packetDescriptions?[index])
                data.append(adtsHeader(length: Int(packet.mDataByteSize)))
                data.append(packets.data.assumingMemoryBound(to: UInt8.self) + Int(packet.mStartOffset), count: Int(packet.mDataByteSize))
            }
            if status == .endOfStream || status == .error {
                break
            }
        }
        return data
    }

    /// ADTS の見出し（AAC LC・44.1 kHz・2 ch・CRC なし）
    static func adtsHeader(length: Int) -> Data {
        let frameLength = length + 7
        let profile = 1, frequencyIndex = 4, channels = 2
        return Data([
            0xFF,
            0xF1,
            UInt8((profile << 6) | (frequencyIndex << 2) | (channels >> 2)),
            UInt8(((channels & 3) << 6) | (frameLength >> 11)),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8(((frameLength & 7) << 5) | 0x1F),
            0xFC
        ])
    }

    /// 細かく分けて渡しても、つなげて読み、48 kHz にして時刻どおりに切れ目なく出す（timestampOffset を足す）
    @Test
    func decodesChunkedStream() async throws {
        let data = try Self.makeADTS(seconds: 2)
        let collected = Collected()
        let decoder = collected.makeDecoder()
        decoder.start(initialization: data.prefix(1_000), timestampOffset: 10)
        var offset = 1_000
        while offset < data.count {
            let end = min(offset + 700, data.count)
            decoder.append(data.subdata(in: offset..<end), timestampOffset: 10)
            offset = end
        }
        // 最後のフレームは、続きが無いと分かる（やめる）まで出ないことがあるので、1.5 秒分まで待つ
        await collected.wait(for: 72_000)
        decoder.stop()
        let blocks = collected.blocks.withLock { $0 }
        let first = try #require(blocks.first)
        #expect(abs(first.time - 10) < 0.001)
        var expected = first.time
        for block in blocks {
            #expect(abs(block.time - expected) < 0.001)
            expected = block.time + Double(block.frames) / 48_000
        }
        #expect(collected.frames >= 72_000)
        // エンコーダーの頭の無音（priming）のあとは、音がある
        #expect(blocks.dropFirst(4).allSatisfy { $0.peak > 0.1 })
        let statuses = collected.statuses.withLock { $0 }
        #expect(statuses.count == 1)
        guard case let .opened(description) = statuses.first else {
            Issue.record("開けたと知らせていない：\(statuses)")
            return
        }
        #expect(description.contains("aac 44100 Hz 2 ch"))
    }

    /// 初期化の断片から読み直すと、前の流れ（続きを待っている）は捨てて、新しい流れの時刻で出す
    @Test
    func restartsFromNewInitialization() async throws {
        let data = try Self.makeADTS(seconds: 3)
        let collected = Collected()
        let decoder = collected.makeDecoder()
        decoder.start(initialization: data.prefix(1_000), timestampOffset: 0)
        try await Task.sleep(for: .milliseconds(200))
        decoder.start(initialization: data, timestampOffset: 100)
        await collected.wait(for: 2 * 48_000)
        decoder.stop()
        let blocks = collected.blocks.withLock { $0 }
        #expect(blocks.allSatisfy { $0.time >= 100 })
        #expect(blocks.first.map { abs($0.time - 100) < 0.001 } == true)
        #expect(collected.frames >= 2 * 48_000)
    }
}
#endif
