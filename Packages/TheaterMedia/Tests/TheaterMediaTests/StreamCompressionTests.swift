//
//  StreamCompressionTests.swift
//  TheaterMediaTests
//
//  AC-3・E-AC-3 のストリームの DRC を「音量の幅」に合わせてかけるか。
//  テスト用のファイルは、どのフレームにも -12.04 dB の DRC の値が入っている（作り方は Fixtures/README.md）。
//

import CFFmpeg
import CinemaAudio
import Foundation
import Testing
@testable import TheaterMedia

private let fixtures = ["dynrng-12db.ac3", "dynrng-12db.eac3"]
/// テスト用のファイルの DRC の値（dynrng の 0xC0 = 1/4 倍）
private let fixtureCompressionDB = 20 * log10(0.25)
/// テスト用のファイルの音の実効値（振幅 0.1 の正弦波）
private let fixtureLevelDB = 20 * log10(0.1 / 2.0.squareRoot())

struct StreamCompressionTests {
    @Test func scaleFollowsDynamicRange() {
        #expect(StreamCompression.scale(for: .cinema) == 0)
        #expect(StreamCompression.scale(for: .standard) == 0)
        #expect(StreamCompression.scale(for: .night) == 1)
    }

    @Test func appliesOnlyToDolbyDigital() {
        #expect(StreamCompression.applies(to: AV_CODEC_ID_AC3))
        #expect(StreamCompression.applies(to: AV_CODEC_ID_EAC3))
        #expect(!StreamCompression.applies(to: AV_CODEC_ID_AAC))
        #expect(!StreamCompression.applies(to: AV_CODEC_ID_DTS))
        #expect(!StreamCompression.applies(to: AV_CODEC_ID_TRUEHD))
    }

    /// AudioDecoder が、開くときに「音量の幅」の drc_scale を渡す（FFmpeg の AVOption を読み返す）
    @Test(arguments: fixtures, CinemaAudioSettings.DynamicRange.allCases)
    func decoderOpensWithScale(file: String, range: CinemaAudioSettings.DynamicRange) throws {
        let fixture = try Fixture(file)
        fixture.processor.update(settings: .with(range))
        let decoder = try fixture.makeAudioDecoder()
        #expect(decoder.streamCompressionScale == StreamCompression.scale(for: range))
    }

    /// 再生中に「音量の幅」を変えると、デコーダーを開き直さずに drc_scale が変わる
    @Test(arguments: fixtures)
    func decoderFollowsChangedRange(file: String) throws {
        let fixture = try Fixture(file)
        fixture.processor.update(settings: .with(.cinema))
        let decoder = try fixture.makeAudioDecoder()
        #expect(decoder.streamCompressionScale == 0)
        fixture.processor.update(settings: .with(.night))
        decoder.followDynamicRange()
        #expect(decoder.streamCompressionScale == 1)
        fixture.processor.update(settings: .with(.standard))
        decoder.followDynamicRange()
        #expect(decoder.streamCompressionScale == 0)
    }

    /// デコードした音の大きさ：映画館・標準はストリームの DRC をかけず、夜はかける
    @Test(arguments: fixtures)
    func decodedLevelFollowsScale(file: String) throws {
        let cinema = try median(Fixture(file).decodedLevels(range: .cinema))
        let standard = try median(Fixture(file).decodedLevels(range: .standard))
        let night = try median(Fixture(file).decodedLevels(range: .night))
        #expect(abs(cinema - fixtureLevelDB) < 1)
        #expect(abs(standard - cinema) < 0.1)
        #expect(abs(night - (cinema + fixtureCompressionDB)) < 0.5)
    }

    /// デコードの途中で drc_scale を変えると、開き直さなくても次のパケットから効く
    @Test(arguments: fixtures)
    func changedScaleTakesEffectOnNextPacket(file: String) throws {
        let switchAt = 8
        let levels = try Fixture(file).decodedLevels(range: .cinema, switchingTo: .night, at: switchAt)
        // 切り替えたパケットのフレームは、前のブロックとの重なりで前の大きさが混じるので見ない
        let before = median(Array(levels[..<switchAt]))
        let after = median(Array(levels[(switchAt + 1)...]))
        #expect(abs(before - fixtureLevelDB) < 1)
        #expect(abs(after - (before + fixtureCompressionDB)) < 0.5)
    }
}

private extension CinemaAudioSettings {
    static func with(_ range: DynamicRange) -> Self {
        var settings = Self()
        settings.dynamicRange = range
        return settings
    }
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? -.infinity : sorted[sorted.count / 2]
}

/// テスト用のファイルを開いたもの
private final class Fixture {
    let container: MediaContainer
    let streamIndex: Int
    let processor: CinemaProcessor

    init(_ file: String) throws {
        let url = try #require(Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Fixtures"))
        container = try MediaContainer(url: url)
        streamIndex = Int(av_find_best_stream(container.context, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0))
        try #require(streamIndex >= 0)
        processor = try CinemaProcessor(speakers: [.left, .right, .center, .lfe])
    }

    var stream: UnsafeMutablePointer<AVStream> {
        get throws {
            try #require(container.stream(streamIndex))
        }
    }

    func makeAudioDecoder() throws -> AudioDecoder {
        try AudioDecoder(
            stream: stream,
            index: streamIndex,
            startTime: 0,
            control: PlaybackControl(),
            processor: processor,
            ring: SpeakerFeedRing(feeds: processor.feeds.count),
            timeline: AudioTimeline()
        )
    }

    /// 全部のパケットをデコードし、フレームごとの左前の実効値（dBFS）を返す。
    /// 始めの 2 フレーム（エンコーダーの遅れの無音を含む）と最後のフレームは返さない。
    /// switchingTo があれば、at 番目のパケットを送る前に drc_scale を変える（返す配列の at 番目がそのパケットのフレーム）
    func decodedLevels(
        range: CinemaAudioSettings.DynamicRange,
        switchingTo next: CinemaAudioSettings.DynamicRange? = nil,
        at switchPacket: Int = 0
    ) throws -> [Double] {
        let parameters = try #require(stream.pointee.codecpar)
        let decoder = try #require(avcodec_find_decoder(parameters.pointee.codec_id))
        var context = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&context) }
        let codec = try #require(context)
        try check(avcodec_parameters_to_context(codec, parameters), "設定")
        var options: OpaquePointer?
        StreamCompression.addOptions(for: range, to: &options)
        let opened = avcodec_open2(codec, decoder, &options)
        av_dict_free(&options)
        try check(opened, "開く")
        #expect(StreamCompression.currentScale(of: codec) == StreamCompression.scale(for: range))

        var packet = av_packet_alloc()
        var frame = av_frame_alloc()
        defer {
            av_packet_free(&packet)
            av_frame_free(&frame)
        }
        let packetPointer = try #require(packet)
        let framePointer = try #require(frame)
        var levels: [Double] = []
        var sent = 0
        while try container.read(into: packetPointer) {
            defer { av_packet_unref(packetPointer) }
            guard Int(packetPointer.pointee.stream_index) == streamIndex else {
                continue
            }
            if let next, sent == switchPacket + 2 {
                #expect(StreamCompression.apply(next, to: codec))
            }
            try check(avcodec_send_packet(codec, packetPointer), "送る")
            sent += 1
            while avcodec_receive_frame(codec, framePointer) >= 0 {
                defer { av_frame_unref(framePointer) }
                try #require(framePointer.pointee.format == AV_SAMPLE_FMT_FLTP.rawValue)
                levels.append(Self.level(of: framePointer))
            }
        }
        return Array(levels.dropFirst(2).dropLast())
    }

    /// 左前（1 チャンネル目）の実効値（dBFS）
    private static func level(of frame: UnsafeMutablePointer<AVFrame>) -> Double {
        let count = Int(frame.pointee.nb_samples)
        guard count > 0, let data = tp_frame_data(frame, 0) else {
            return -.infinity
        }
        let samples = UnsafeRawPointer(data).assumingMemoryBound(to: Float.self)
        var power = 0.0
        for index in 0..<count {
            power += Double(samples[index] * samples[index])
        }
        return 10 * log10(power / Double(count) + 1e-20)
    }
}
