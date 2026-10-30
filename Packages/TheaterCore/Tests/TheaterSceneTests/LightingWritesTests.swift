//
//  LightingWritesTests.swift
//  TheaterSceneTests
//

import Foundation
import Testing
@testable import TheaterScene

struct LightingWritesTests {
    func texels(exposure: Float) -> [SIMD4<Float16>] {
        var values = LightingValues()
        values.exposure = exposure
        return values.texels(order: ["house": 0, "exposure": 1], width: 2).map { SIMD4<Float16>($0) }
    }

    /// まだ何も書いていなければ、すぐに書く
    @Test func writesTheFirstValuesAtOnce() {
        #expect(LightingWrites().shouldWrite(texels(exposure: 1), at: 0))
    }

    /// 画素（Float16）が変わらないほどの小さな変化では書かない（暗転から戻ったあと、明るさが 1 に近づき続けるあいだ）
    @Test func skipsChangesTooSmallForTheTexture() {
        var writes = LightingWrites()
        writes.didWrite(texels(exposure: 1), at: 0)
        #expect(!writes.shouldWrite(texels(exposure: 0.99999), at: 1))
        #expect(writes.shouldWrite(texels(exposure: 0.9), at: 1))
    }

    /// 前に書いてから間隔の下限がたつまでは書かず、たったら（値がもう変わっていなくても）最後の値を書く
    @Test func waitsForTheIntervalThenWritesTheLatest() {
        var writes = LightingWrites()
        writes.didWrite(texels(exposure: 1), at: 0)
        let latest = texels(exposure: 0.5)
        #expect(!writes.shouldWrite(latest, at: LightingWrites.minimumInterval / 2))
        #expect(writes.shouldWrite(latest, at: LightingWrites.minimumInterval))
        writes.didWrite(latest, at: LightingWrites.minimumInterval)
        #expect(!writes.shouldWrite(latest, at: 10))
    }
}
