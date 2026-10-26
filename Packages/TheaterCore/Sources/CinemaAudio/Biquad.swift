//
//  Biquad.swift
//  CinemaAudio
//
//  2 次の IIR フィルター（RBJ の Audio EQ Cookbook）と、Linkwitz-Riley（4 次）のクロスオーバー。
//

import Foundation

/// 2 次の IIR フィルター（転置直接形 II）
public struct Biquad: Sendable {
    var b0: Float = 1
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0
    private var z1: Float = 0
    private var z2: Float = 0

    init(b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    /// 何もしないフィルター
    public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a0: 1, a1: 0, a2: 0)

    @inline(__always)
    public mutating func process(_ input: Float) -> Float {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }

    public mutating func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        for index in 0..<count {
            buffer[index] = process(buffer[index])
        }
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }

    // MARK: - 係数

    private struct Terms {
        let cosine: Float
        let alpha: Float

        init(frequency: Float, quality: Float, sampleRate: Float) {
            let omega = 2 * Float.pi * min(frequency, sampleRate * 0.49) / sampleRate
            cosine = cos(omega)
            alpha = sin(omega) / (2 * quality)
        }
    }

    public static func lowPass(frequency: Float, quality: Float = 0.707_106_8, sampleRate: Float) -> Biquad {
        let terms = Terms(frequency: frequency, quality: quality, sampleRate: sampleRate)
        let gain = (1 - terms.cosine) / 2
        return Biquad(b0: gain, b1: 1 - terms.cosine, b2: gain, a0: 1 + terms.alpha, a1: -2 * terms.cosine, a2: 1 - terms.alpha)
    }

    public static func highPass(frequency: Float, quality: Float = 0.707_106_8, sampleRate: Float) -> Biquad {
        let terms = Terms(frequency: frequency, quality: quality, sampleRate: sampleRate)
        let gain = (1 + terms.cosine) / 2
        return Biquad(b0: gain, b1: -(1 + terms.cosine), b2: gain, a0: 1 + terms.alpha, a1: -2 * terms.cosine, a2: 1 - terms.alpha)
    }

    /// 低い音域を gainDB だけ持ち上げる（下げる）棚型
    public static func lowShelf(frequency: Float, gainDB: Float, sampleRate: Float) -> Biquad {
        let amp = pow(10, gainDB / 40)
        let omega = 2 * Float.pi * frequency / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / 2 * sqrt(2)
        let root = 2 * sqrt(amp) * alpha
        return Biquad(
            b0: amp * ((amp + 1) - (amp - 1) * cosine + root),
            b1: 2 * amp * ((amp - 1) - (amp + 1) * cosine),
            b2: amp * ((amp + 1) - (amp - 1) * cosine - root),
            a0: (amp + 1) + (amp - 1) * cosine + root,
            a1: -2 * ((amp - 1) + (amp + 1) * cosine),
            a2: (amp + 1) + (amp - 1) * cosine - root
        )
    }

    /// ある周波数のまわりを持ち上げる（下げる）山型
    public static func peaking(frequency: Float, quality: Float, gainDB: Float, sampleRate: Float) -> Biquad {
        let amp = pow(10, gainDB / 40)
        let terms = Terms(frequency: frequency, quality: quality, sampleRate: sampleRate)
        return Biquad(
            b0: 1 + terms.alpha * amp,
            b1: -2 * terms.cosine,
            b2: 1 - terms.alpha * amp,
            a0: 1 + terms.alpha / amp,
            a1: -2 * terms.cosine,
            a2: 1 - terms.alpha / amp
        )
    }
}

/// Linkwitz-Riley の 4 次（2 次の Butterworth を 2 段）。低域と高域を足すと元の振幅に戻る（位相は全域通過）
public struct LinkwitzRiley: Sendable {
    private var lowStages: (Biquad, Biquad)
    private var highStages: (Biquad, Biquad)

    public init(frequency: Float, sampleRate: Float) {
        let low = Biquad.lowPass(frequency: frequency, sampleRate: sampleRate)
        let high = Biquad.highPass(frequency: frequency, sampleRate: sampleRate)
        lowStages = (low, low)
        highStages = (high, high)
    }

    /// 低域だけ
    @inline(__always)
    public mutating func low(_ input: Float) -> Float {
        lowStages.1.process(lowStages.0.process(input))
    }

    /// 高域だけ
    @inline(__always)
    public mutating func high(_ input: Float) -> Float {
        highStages.1.process(highStages.0.process(input))
    }

    public mutating func reset() {
        lowStages.0.reset()
        lowStages.1.reset()
        highStages.0.reset()
        highStages.1.reset()
    }
}
