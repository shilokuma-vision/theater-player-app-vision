//
//  ProcessorTests.swift
//  CinemaAudioTests
//

@testable import CinemaAudio
import Foundation
import Testing

/// CinemaProcessor に入力を通して、スピーカーごとの出力を返す
func process(_ processor: CinemaProcessor, input: [[Float]], block: Int = 1_024) -> [[Float]] {
    let frames = input[0].count
    let inputs = input.map { channel -> UnsafeMutablePointer<Float> in
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        pointer.initialize(from: channel, count: frames)
        return pointer
    }
    let outputs = processor.feeds.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
    defer {
        inputs.forEach { $0.deallocate() }
        outputs.forEach { $0.deallocate() }
    }
    for start in stride(from: 0, to: frames, by: block) {
        let count = min(block, frames - start)
        processor.process(input: inputs.map { UnsafePointer($0 + start) }, frames: count, output: outputs.map { $0 + start })
    }
    return outputs.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
}

func peakIndex(_ signal: [Float]) -> Int {
    signal.indices.max { abs(signal[$0]) < abs(signal[$1]) } ?? 0
}

struct ProcessorTests {
    let speakers: [CinemaBus] = [
        .left, .center, .right, .lfe, .leftSideSurround, .leftSideSurround, .rightSideSurround,
        .leftRearSurround, .rightRearSurround
    ]

    func flatSettings() -> CinemaAudioSettings {
        var settings = CinemaAudioSettings()
        settings.bassBoostDB = 0
        settings.rumble = 0
        settings.virtualBass = 0
        settings.heightAmount = 0
        return settings
    }

    @Test func latencyIsTheSameWithAndWithoutUpmix() throws {
        let frames = 8_192
        var impulse = [Float](repeating: 0, count: frames)
        impulse[1_000] = 0.5
        let silent = [Float](repeating: 0, count: frames)
        let passthrough = try CinemaProcessor(speakers: speakers)
        passthrough.update(settings: flatSettings())
        passthrough.configure(input: [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .sideLeft, .sideRight])
        let direct = process(passthrough, input: [silent, silent, impulse, silent, silent, silent])
        let upmixing = try CinemaProcessor(speakers: speakers)
        upmixing.update(settings: flatSettings())
        upmixing.configure(input: [.frontLeft, .frontRight])
        let upmixed = process(upmixing, input: [impulse, impulse])
        let expected = 1_000 + CinemaProcessor.latencyFrames
        #expect(abs(peakIndex(direct[1]) - expected) < 8)
        #expect(abs(peakIndex(upmixed[1]) - expected) < 8)
    }

    @Test func lfeAndBassGoToTheSubwoofer() throws {
        let processor = try CinemaProcessor(speakers: speakers)
        processor.update(settings: flatSettings())
        processor.configure(input: [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .sideLeft, .sideRight])
        let bass = sine(frequency: 40, amplitude: 0.2, frames: 48_000)
        let silent = [Float](repeating: 0, count: 48_000)
        let output = process(processor, input: [silent, silent, bass, silent, silent, silent])
        // センターの 40 Hz は、サブウーファーへ移る
        #expect(steadyRMS(output[3]) > steadyRMS(output[1]) * 10)
    }

    @Test func limiterKeepsTheOutputUnderTheCeiling() throws {
        let processor = try CinemaProcessor(speakers: speakers)
        processor.update(settings: CinemaAudioSettings())
        processor.configure(input: [.frontCenter])
        let loud = sine(frequency: 50, amplitude: 1.5, frames: 48_000)
        let output = process(processor, input: [loud])
        let peak = output.map { $0.map(abs).max() ?? 0 }.max() ?? 0
        #expect(peak <= 0.9)
        #expect(peak > 0.5)
    }

    @Test func surroundArraysShareThePower() {
        let feeds = SpeakerFeed.feeds(for: [.leftSideSurround, .leftSideSurround, .leftSideSurround, .leftSideSurround, .center],
                                      sampleRate: 48_000)
        #expect(abs(feeds[0].gain - 0.5) < 1e-5)
        #expect(feeds[4].gain == 1)
        #expect(Set(feeds.prefix(4).map(\.delayFrames)).count == 4)
        #expect(feeds[4].delayFrames == 0)
    }
}
