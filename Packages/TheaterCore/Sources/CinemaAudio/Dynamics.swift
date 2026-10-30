//
//  Dynamics.swift
//  CinemaAudio
//
//  音量の幅（ダイナミックレンジ）の調整と、音割れを防ぐリミッター。どちらも全部のスピーカーで同じ倍率を掛ける（定位を崩さない）。
//

import Foundation

/// 音量の幅の調整（コンプレッサー）。小さな音を聞きやすく、大きな音を抑える
struct DynamicRangeController {
    private var power: Float = 0
    private var gainDB: Float = 0
    private let detector: Float
    private let attack: Float
    private let release: Float

    init(sampleRate: Float) {
        detector = exp(-1 / (0.05 * sampleRate))
        attack = exp(-1 / (0.015 * sampleRate))
        release = exp(-1 / (0.4 * sampleRate))
    }

    /// 入力の力（全系統の 2 乗の和）から、そのサンプルに掛ける倍率を返す
    @inline(__always)
    mutating func gain(power input: Float, mode: CinemaAudioSettings.DynamicRange) -> Float {
        guard let curve = mode.curve else {
            return 1
        }
        power = detector * power + (1 - detector) * input
        let level = 10 * log10(power + 1e-12)
        let over = level - curve.threshold
        // 6 dB の幅でなだらかに効き始める
        let knee: Float = 6
        let reduction: Float
        if over <= -knee / 2 {
            reduction = 0
        } else if over >= knee / 2 {
            reduction = over * (1 - 1 / curve.ratio)
        } else {
            let into = over + knee / 2
            reduction = (1 - 1 / curve.ratio) * into * into / (2 * knee)
        }
        let target = curve.makeup - reduction
        let coefficient = target < gainDB ? attack : release
        gainDB = coefficient * gainDB + (1 - coefficient) * target
        return pow(10, gainDB / 20)
    }

    mutating func reset() {
        power = 0
        gainDB = 0
    }
}

/// 先読みのリミッター（約 2 ms 先を見て、超える前に下げる）
///
/// 倍率は段差にしない（大きな音の最中に倍率が急に変わるとクリックが出る）。
/// 1. 各入力のサンプルが求める倍率（上限 ÷ ピーク）の、直近 lookahead + 1 サンプルの最小値を取る
/// 2. それをゆっくり戻す（下げるときはそのまま）
/// 3. 直近 lookahead サンプルの平均を倍率にする
/// 出力は lookahead サンプル遅れるので、あるサンプルが出るときの平均の範囲は、どれもそのサンプルの最小値の範囲に入る。
/// そのため倍率はそのサンプルの求める倍率以下になり、上限を超えない
struct LookaheadLimiter {
    static let lookahead = 96
    /// 上限（-1 dBFS）
    let threshold: Float = 0.89
    private var delayed: [[Float]]
    /// 入力のサンプルごとの求める倍率（直近 lookahead + 1 サンプル）
    private var required: [Float]
    private var requiredPosition = 0
    /// 最小値をゆっくり戻した倍率（直近 lookahead サンプル。平均を取る）
    private var held: [Float]
    private var hold: Float = 1
    private var position = 0
    private let release: Float

    init(channels: Int, sampleRate: Float) {
        delayed = [[Float]](repeating: [Float](repeating: 0, count: Self.lookahead), count: channels)
        required = [Float](repeating: 1, count: Self.lookahead + 1)
        held = [Float](repeating: 1, count: Self.lookahead)
        release = exp(-1 / (0.08 * sampleRate))
    }

    /// 全チャンネルを同じ倍率で抑える。出力は入力から lookahead サンプル遅れる
    mutating func process(_ buffers: [UnsafeMutablePointer<Float>], frames: Int) {
        let channels = buffers.count
        for frame in 0..<frames {
            var peak: Float = 0
            for channel in 0..<channels {
                peak = max(peak, abs(buffers[channel][frame]))
            }
            required[requiredPosition] = peak > threshold ? threshold / peak : 1
            requiredPosition = (requiredPosition + 1) % required.count
            let minimum = required.min() ?? 1
            hold = minimum < hold ? minimum : release * hold + (1 - release) * minimum
            held[position] = hold
            let gain = held.reduce(0, +) / Float(held.count)
            for channel in 0..<channels {
                let input = buffers[channel][frame]
                buffers[channel][frame] = delayed[channel][position] * gain
                delayed[channel][position] = input
            }
            position = (position + 1) % Self.lookahead
        }
    }

    mutating func reset() {
        for channel in delayed.indices {
            for index in delayed[channel].indices {
                delayed[channel][index] = 0
            }
        }
        for index in required.indices {
            required[index] = 1
        }
        for index in held.indices {
            held[index] = 1
        }
        hold = 1
        requiredPosition = 0
        position = 0
    }
}

/// 遅延（サンプル単位）。0 なら素通し
struct DelayLine {
    private var buffer: [Float]
    private var position = 0
    let frames: Int

    init(frames: Int) {
        self.frames = max(0, frames)
        buffer = [Float](repeating: 0, count: max(1, frames))
    }

    @inline(__always)
    mutating func process(_ input: Float) -> Float {
        guard frames > 0 else {
            return input
        }
        let output = buffer[position]
        buffer[position] = input
        position += 1
        if position == buffer.count {
            position = 0
        }
        return output
    }

    mutating func reset() {
        for index in buffer.indices {
            buffer[index] = 0
        }
        position = 0
    }
}
