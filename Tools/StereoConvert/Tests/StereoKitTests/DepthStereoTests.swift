//
//  DepthStereoTests.swift
//  StereoKitTests
//

import StereoKit
import Testing

struct DepthStereoTests {
    /// 深度は 0〜1 にそろい、近いほど大きいまま
    @Test func normalizesToZeroOne() {
        let normalizer = DepthNormalizer(smoothing: 0)
        let result = normalizer.normalize((0..<100).map(Float.init))
        #expect(result.first == 0)
        #expect(result.last == 1)
        #expect(result == result.sorted())
    }

    /// 範囲はコマをまたいでならすので、急に明るく（近く）なった 1 コマでも、そろえた値は跳ねない
    @Test func smoothsTheRangeAcrossFrames() {
        let normalizer = DepthNormalizer(smoothing: 0.9)
        _ = normalizer.normalize((0..<100).map(Float.init))
        let jumped = normalizer.normalize((0..<100).map { Float($0) * 3 })
        // ならさなければ 50 番目は約 0.5。範囲がまだ前のコマに近いので、1 に張り付く側へ寄る
        #expect(jumped[50] > 0.6)
    }

    /// 収束の深さの物はずれず、近い物は左目で右へずれる
    @Test func shiftsNearObjectsAndKeepsTheConvergencePlane() {
        let parameters = StereoParameters(strength: 0.1, convergence: 0.5)
        #expect(StereoWarp.shift(depth: 0.5, width: 100, parameters: parameters) == 0)
        #expect(StereoWarp.shift(depth: 1, width: 100, parameters: parameters) > 0)
        #expect(StereoWarp.shift(depth: 0, width: 100, parameters: parameters) < 0)
    }

    /// 近い物（深度 1）は、左目の絵（左半分）では右へ、右目の絵（右半分）では左へ動く
    @Test func rendersOppositeShiftsForTheEyes() {
        let width = 32
        // 真ん中に 1 本だけ白い縦の線。全体が近い（深度 1）
        var source = [UInt32](repeating: 0, count: width)
        source[16] = 0xFFFF_FFFF
        let depth = [Float](repeating: 1, count: width)
        var output = [UInt32](repeating: 0, count: width * 2)
        source.withUnsafeBufferPointer { sourcePointer in
            output.withUnsafeMutableBufferPointer { outputPointer in
                guard let sourceBase = sourcePointer.baseAddress, let outputBase = outputPointer.baseAddress else {
                    return
                }
                StereoWarp.render(
                    SourceImage(base: sourceBase, stride: width, width: width, height: 1),
                    depth: depth,
                    into: StereoTarget(left: outputBase, right: outputBase + width, stride: width * 2),
                    parameters: StereoParameters(strength: 0.25, convergence: 0)
                )
            }
        }
        let leftLine = output.prefix(width).firstIndex(of: 0xFFFF_FFFF) ?? -1
        let rightLine = (output.suffix(width).firstIndex(of: 0xFFFF_FFFF) ?? -1) - width
        #expect(leftLine > 16)
        #expect((0..<16).contains(rightLine))
    }

    @Test func resamplesKeepingTheCorners() {
        let resized = DepthResampler.resample([0, 1, 2, 3], width: 2, height: 2, toWidth: 4, toHeight: 4)
        #expect(resized.first == 0)
        #expect(resized.last == 3)
    }
}
