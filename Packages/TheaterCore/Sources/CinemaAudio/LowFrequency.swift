//
//  LowFrequency.swift
//  CinemaAudio
//
//  映画館の低音。
//  - ベースマネジメント：すべての系統の 80 Hz より下をサブウーファーへ集める（LFE は +10 dB の決まりで足す）
//  - 低音の量：サブウーファーの 60 Hz より下を持ち上げる棚型のイコライザー
//  - 低音の残響：大きな部屋の低音が長く残る響き（低域だけを回す遅延の網）
//  - 体感の低音：小さなスピーカー（Vision Pro の音響ポッド）でも低音を感じやすいよう、低音の倍音（2・3 倍音）を足す
//    （基音が無くても倍音から音の高さを感じる「ミッシングファンダメンタル」を使う）
//

import Foundation

/// ベースマネジメント
struct BassManager {
    private var crossovers: [LinkwitzRiley]
    private var lfeFilter: LinkwitzRiley
    private let lfeIndex = CinemaBus.lfe.index

    init(frequency: Float, sampleRate: Float) {
        crossovers = CinemaBus.allCases.map { _ in LinkwitzRiley(frequency: frequency, sampleRate: sampleRate) }
        lfeFilter = LinkwitzRiley(frequency: 120, sampleRate: sampleRate)
    }

    /// buses の各系統から低域を抜いて sub に足す。LFE は lfeGain を掛けて sub に足し、系統からは消す
    mutating func process(buses: [UnsafeMutablePointer<Float>], sub: UnsafeMutablePointer<Float>, frames: Int, lfeGain: Float) {
        for frame in 0..<frames {
            var low: Float = 0
            for bus in 0..<buses.count {
                let value = buses[bus][frame]
                if bus == lfeIndex {
                    low += lfeFilter.low(value) * lfeGain
                    buses[bus][frame] = 0
                } else {
                    low += crossovers[bus].low(value)
                    buses[bus][frame] = crossovers[bus].high(value)
                }
            }
            sub[frame] = low
        }
    }

    mutating func reset() {
        for index in crossovers.indices {
            crossovers[index].reset()
        }
        lfeFilter.reset()
    }
}

/// 低音の残響（4 本の遅延の網。低域だけを回す）
struct LowFrequencyReverb {
    private var lines: [[Float]]
    private var positions: [Int]
    private var damping: [Float]
    private var gains: [Float]
    private let smoothing: Float

    init(sampleRate: Float, decaySeconds: Float) {
        let lengths = [0.041, 0.059, 0.073, 0.089].map { Int(Float($0) * sampleRate) }
        lines = lengths.map { [Float](repeating: 0, count: $0) }
        positions = [Int](repeating: 0, count: lengths.count)
        damping = [Float](repeating: 0, count: lengths.count)
        // 1 回まわるごとの減衰（decaySeconds で -60 dB）
        gains = lengths.map { pow(10, -3 * Float($0) / sampleRate / max(decaySeconds, 0.1)) }
        // 遅延の中の 1 次の低域通過（約 150 Hz）
        smoothing = exp(-2 * Float.pi * 150 / sampleRate)
    }

    /// 1 サンプル。入力を受け取り、残響（入力を含まない）を返す
    @inline(__always)
    mutating func process(_ input: Float) -> Float {
        let out0 = lines[0][positions[0]]
        let out1 = lines[1][positions[1]]
        let out2 = lines[2][positions[2]]
        let out3 = lines[3][positions[3]]
        // ハウスホルダー行列で混ぜて戻す（4 本なら和の半分を引く）
        let mixed = (out0 + out1 + out2 + out3) * 0.5
        write(line: 0, feedback: (out0 - mixed) * gains[0], input: input)
        write(line: 1, feedback: (out1 - mixed) * gains[1], input: input)
        write(line: 2, feedback: (out2 - mixed) * gains[2], input: input)
        write(line: 3, feedback: (out3 - mixed) * gains[3], input: input)
        return (out0 - out1 + out2 - out3) * 0.5
    }

    @inline(__always)
    private mutating func write(line: Int, feedback: Float, input: Float) {
        damping[line] = smoothing * damping[line] + (1 - smoothing) * (feedback + input * 0.5)
        lines[line][positions[line]] = damping[line]
        positions[line] += 1
        if positions[line] == lines[line].count {
            positions[line] = 0
        }
    }
}

/// 体感の低音（低音の倍音を作る）
struct VirtualBass {
    private var bandLow: (Biquad, Biquad)
    private var bandHigh: (Biquad, Biquad)
    private var envelope: Float = 0
    private let attack: Float
    private let release: Float

    init(sampleRate: Float) {
        bandLow = (Biquad.highPass(frequency: 28, sampleRate: sampleRate), Biquad.lowPass(frequency: 110, sampleRate: sampleRate))
        bandHigh = (Biquad.highPass(frequency: 95, sampleRate: sampleRate), Biquad.lowPass(frequency: 420, sampleRate: sampleRate))
        attack = exp(-1 / (0.004 * sampleRate))
        release = exp(-1 / (0.08 * sampleRate))
    }

    /// 低音 input から、その 2・3 倍音を返す（大きさは低音の大きさに合わせる）
    @inline(__always)
    mutating func process(_ input: Float) -> Float {
        let low = bandLow.1.process(bandLow.0.process(input))
        let level = abs(low)
        envelope = level > envelope ? attack * envelope + (1 - attack) * level : release * envelope + (1 - release) * level
        guard envelope > 1e-6 else {
            return bandHigh.1.process(bandHigh.0.process(0))
        }
        // 振幅をそろえてからチェビシェフ多項式で倍音を作る：T2(u) = 2u² - 1、T3(u) = 4u³ - 3u
        let unit = max(-1, min(1, low / (envelope * 1.414)))
        let harmonics = 0.6 * (2 * unit * unit - 1) + 0.4 * (4 * unit * unit * unit - 3 * unit)
        return bandHigh.1.process(bandHigh.0.process(harmonics * envelope))
    }
}
