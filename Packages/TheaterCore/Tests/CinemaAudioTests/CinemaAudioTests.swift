//
//  CinemaAudioTests.swift
//  CinemaAudioTests
//

@testable import CinemaAudio
import Foundation
import Testing

/// 正弦波
func sine(frequency: Float, amplitude: Float = 0.5, frames: Int, sampleRate: Float = 48_000) -> [Float] {
    (0..<frames).map { amplitude * sin(2 * Float.pi * frequency * Float($0) / sampleRate) }
}

/// 後ろ半分の実効値（フィルターが落ち着いた所）
func steadyRMS(_ signal: [Float]) -> Float {
    let tail = signal.suffix(signal.count / 2)
    return (tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count)).squareRoot()
}

/// 白色雑音（再現できる乱数。SplitMix64）
func noise(frames: Int, seed: UInt64) -> [Float] {
    var state = seed &* 0x9E37_79B9_7F4A_7C15
    return (0..<frames).map { _ in
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        mixed ^= mixed >> 31
        return (Float(mixed >> 40) / Float(1 << 24) - 0.5) * 0.5
    }
}

struct CrossoverTests {
    @Test(arguments: [30, 80, 160, 1_000] as [Float])
    func lowAndHighSumKeepsTheLevel(frequency: Float) {
        var crossover = LinkwitzRiley(frequency: 80, sampleRate: 48_000)
        let input = sine(frequency: frequency, frames: 48_000)
        let output = input.map { crossover.low($0) + crossover.high($0) }
        #expect(abs(steadyRMS(output) / steadyRMS(input) - 1) < 0.02)
    }

    @Test func lowPassRemovesHighFrequencies() {
        var crossover = LinkwitzRiley(frequency: 80, sampleRate: 48_000)
        let input = sine(frequency: 1_000, frames: 24_000)
        let low = input.map { crossover.low($0) }
        #expect(steadyRMS(low) < steadyRMS(input) * 0.001)
    }

    @Test func lowShelfBoostsBass() {
        var shelf = Biquad.lowShelf(frequency: 60, gainDB: 6, sampleRate: 48_000)
        let input = sine(frequency: 30, frames: 48_000)
        let output = input.map { shelf.process($0) }
        let gainDB = 20 * log10(steadyRMS(output) / steadyRMS(input))
        #expect(gainDB > 4.5 && gainDB < 6.5)
    }
}

struct ChannelMatrixTests {
    @Test func surroundOf51GoesToSideAndRear() {
        let matrix = ChannelMatrix(layout: [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .sideLeft, .sideRight])
        let left = matrix.gains[4]
        #expect(abs(left[CinemaBus.leftSideSurround.index] - ChannelMatrix.half) < 1e-5)
        #expect(abs(left[CinemaBus.leftRearSurround.index] - ChannelMatrix.half) < 1e-5)
        #expect(matrix.gains[3][CinemaBus.lfe.index] == 1)
        #expect(!matrix.isStereo)
        #expect(!matrix.hasHeight)
    }

    @Test func surroundOf71IsSeparated() {
        let matrix = ChannelMatrix(layout: [
            .frontLeft, .frontRight, .frontCenter, .lowFrequency, .backLeft, .backRight,
            .sideLeft, .sideRight
        ])
        #expect(matrix.gains[4][CinemaBus.leftRearSurround.index] == 1)
        #expect(matrix.gains[6][CinemaBus.leftSideSurround.index] == 1)
        #expect(matrix.gains[6][CinemaBus.leftRearSurround.index] == 0)
    }

    @Test func monoGoesToCenterAndStereoIsDetected() {
        #expect(ChannelMatrix(layout: [.frontCenter]).gains[0][CinemaBus.center.index] == 1)
        #expect(ChannelMatrix(layout: [.frontLeft, .frontRight]).isStereo)
        #expect(ChannelMatrix(layout: [.frontLeft, .frontRight, .topFrontLeft, .topFrontRight]).hasHeight)
    }
}

struct UpmixTests {
    /// 2 チャンネルを upmixer に通し、5 系統（L・R・C・Ls・Rs）の後ろ半分の実効値を返す
    func run(left: [Float], right: [Float]) throws -> [Float] {
        let upmixer = try StereoUpmixer(sampleRate: 48_000)
        let frames = left.count
        let outputs = (0..<5).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer { outputs.forEach { $0.deallocate() } }
        let block = 480
        left.withUnsafeBufferPointer { leftPointer in
            right.withUnsafeBufferPointer { rightPointer in
                for start in stride(from: 0, to: frames, by: block) {
                    let count = min(block, frames - start)
                    upmixer.process(
                        left: leftPointer.baseAddress! + start,
                        right: rightPointer.baseAddress! + start,
                        count: count,
                        outputs: outputs.map { $0 + start }
                    )
                }
            }
        }
        return outputs.map { steadyRMS(Array(UnsafeBufferPointer(start: $0, count: frames))) }
    }

    @Test func identicalChannelsGoMostlyToCenter() throws {
        let signal = sine(frequency: 440, frames: 48_000)
        let rms = try run(left: signal, right: signal)
        #expect(rms[2] > rms[0] * 2)
        #expect(rms[3] < rms[2] * 0.1)
    }

    @Test func uncorrelatedChannelsGoToSurroundAndNotCenter() throws {
        // SplitMix64 は種が近いと 1 サンプルずれただけの列になるので、離した種を使う
        let rms = try run(left: noise(frames: 48_000, seed: 1), right: noise(frames: 48_000, seed: 1_000_003))
        #expect(rms[3] > rms[2] * 2)
        #expect(rms[0] > rms[2] * 2)
    }
}
