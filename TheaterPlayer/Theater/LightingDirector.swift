//
//  LightingDirector.swift
//  TheaterPlayer
//
//  映画館の照明の演出。毎フレーム、照明の状態（客電・常時灯・スクリーンの光・全体の明るさ）を決める。
//  - 再生が始まると客電をゆっくり落とし（約 6 秒）、止める・終わると戻す（約 4 秒）。暗くするほど電球のように暖かい色になる
//  - 開場（再生していないとき）は、照明を焼き付けたときより明るくできる（客電 1 を超える。色は白のまま）
//  - スクリーンの光：映像の左・中央・右の色で、部屋を照らす（少しだけならして、ちらつかないように）
//

import Foundation
import TheaterMedia
import TheaterScene

@MainActor
final class LightingDirector {
    /// 今の客電の明るさ（0〜4。1 が照明を焼き付けたときの明るさ）
    private(set) var house: Double
    private var zones = [SIMD3<Float>](repeating: .zero, count: 3)
    /// 全体の明るさ（席の移動の暗転）
    var exposure: Double = 1
    private var exposureTarget: Double = 1

    init(initialHouse: Double) {
        house = initialHouse
    }

    /// 暗転して戻す（席を移るとき）。暗くなったら changed を呼ぶ
    func blackout(_ changed: @escaping @MainActor () -> Void) async {
        exposureTarget = 0
        try? await Task.sleep(for: .milliseconds(380))
        changed()
        try? await Task.sleep(for: .milliseconds(120))
        exposureTarget = 1
    }

    /// 1 フレーム分進め、照明の状態を返す
    func step(deltaTime: Double, playing: Bool, hasVideo: Bool, preferences: Preferences, light: ScreenLight?) -> LightingValues {
        let target = preferences.autoDim && playing ? preferences.showLevel : preferences.houseLevel
        // 暗くするときはゆっくり（約 6 秒）、明るくするときは少し速く（約 4 秒）。開場を明るくしても、かかる時間は同じ
        let span = max(preferences.houseLevel, 1)
        let speed = target < house ? span / 6 : span / 4
        house += max(-speed * deltaTime, min(speed * deltaTime, target - house))
        let zoneTargets: [SIMD3<Float>] = hasVideo ? [light?.left, light?.center, light?.right].map {
            ($0 ?? .zero) * Float(preferences.screenSpill)
        } : [SIMD3<Float>](repeating: .zero, count: 3)
        let smoothing = Float(1 - exp(-deltaTime / 0.12))
        for index in zones.indices {
            zones[index] += (zoneTargets[index] - zones[index]) * smoothing
        }
        let fade = 1 - exp(-deltaTime / 0.09)
        exposure += (exposureTarget - exposure) * fade
        return values(preferences: preferences)
    }

    private func values(preferences: Preferences) -> LightingValues {
        var values = LightingValues()
        let level = Float(house)
        // 調光すると色温度が下がる（暖かくなる）。焼き付けたときより明るくするときは白のまま
        let full = min(level, 1)
        let warmth = SIMD3<Float>(1, 0.82 + 0.18 * full, 0.62 + 0.38 * full)
        values.house = warmth * level
        values.houseEmission = warmth * pow(level, 0.8)
        values.ambient = SIMD3(repeating: Float(preferences.ambientLevel))
        values.zoneLeft = zones[0]
        values.zoneCenter = zones[1]
        values.zoneRight = zones[2]
        values.screenAverage = (zones[0] + zones[1] + zones[2]) / 3
        values.exposure = Float(exposure)
        return values
    }
}
