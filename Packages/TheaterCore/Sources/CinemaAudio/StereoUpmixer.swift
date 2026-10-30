//
//  StereoUpmixer.swift
//  CinemaAudio
//
//  ステレオを映画館の 5 系統（L・C・R・左右のサラウンド）に広げる。短時間フーリエ変換（2048 点、1/4 ずつずらす）で、
//  周波数ごとに左右の似ている度合い（コヒーレンス）と定位を見て、
//  - 左右で同じで中央に定位する成分（台詞など）→ センター
//  - 左右で相関の無い成分（残響・環境音）→ サラウンド
//  に分ける（Avendano と Jot の方法に近い）。左右はセンターに分けた分を引いて残す。
//

import Accelerate

final class StereoUpmixer {
    static let size = 2048
    static let hop = size / 4

    /// センターに分ける強さ（0〜1）
    var centerAmount: Float = 0.7
    /// サラウンドに分ける強さ（0〜1）
    var ambienceAmount: Float = 0.6
    /// 出力が入力から遅れる量（サンプル）
    static let latency = size

    private let forward: vDSP.DiscreteFourierTransform<Float>
    private let inverse: vDSP.DiscreteFourierTransform<Float>
    private let window: [Float]
    private let normalization: Float
    private var frameLeft: [Float]
    private var frameRight: [Float]
    private var pendingLeft: [Float] = []
    private var pendingRight: [Float] = []
    /// 出力（L・R・C・Ls・Rs）の重ね合わせの途中と、取り出し待ち
    private var accumulators: [[Float]]
    private var ready: [[Float]]
    private var crossLL: [Float]
    private var crossRR: [Float]
    private var crossLRReal: [Float]
    private var crossLRImaginary: [Float]
    /// 1 回分の計算に使う作業領域（毎回つくらない）
    private let scratch: UpmixScratch
    private let smoothing: Float

    init(sampleRate: Float) throws {
        let size = Self.size
        forward = try vDSP.DiscreteFourierTransform(count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        inverse = try vDSP.DiscreteFourierTransform(count: size, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        // 平方根のハン窓（分析と合成の両方に掛ける）。1/4 ずつずらして重ねると、窓の 2 乗の和は 2 になる
        window = (0..<size).map { sqrt(0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(size))) }
        normalization = 1 / (2 * Float(size))
        frameLeft = [Float](repeating: 0, count: size)
        frameRight = [Float](repeating: 0, count: size)
        accumulators = [[Float]](repeating: [Float](repeating: 0, count: size), count: 5)
        // 取り出しが足りなくならないよう、1 回分ずらした分の 0 を先に入れておく
        ready = [[Float]](repeating: [Float](repeating: 0, count: Self.hop), count: 5)
        crossLL = [Float](repeating: 0, count: size)
        crossRR = [Float](repeating: 0, count: size)
        crossLRReal = [Float](repeating: 0, count: size)
        crossLRImaginary = [Float](repeating: 0, count: size)
        scratch = UpmixScratch(size: size)
        // 似ている度合いをならす時間（約 80 ms）
        smoothing = exp(-Float(Self.hop) / (0.08 * sampleRate))
    }

    /// count サンプルを入れ、同じ数を出す。outputs は L・R・C・Ls・Rs の 5 つ
    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, outputs: [UnsafeMutablePointer<Float>]) {
        pendingLeft.append(contentsOf: UnsafeBufferPointer(start: left, count: count))
        pendingRight.append(contentsOf: UnsafeBufferPointer(start: right, count: count))
        while pendingLeft.count >= Self.hop {
            runFrame()
        }
        for channel in 0..<5 {
            ready[channel].withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else {
                    return
                }
                outputs[channel].update(from: base, count: count)
            }
            ready[channel].removeFirst(count)
        }
    }

    func reset() {
        for index in frameLeft.indices {
            frameLeft[index] = 0
            frameRight[index] = 0
            crossLL[index] = 0
            crossRR[index] = 0
            crossLRReal[index] = 0
            crossLRImaginary[index] = 0
        }
        pendingLeft.removeAll()
        pendingRight.removeAll()
        accumulators = [[Float]](repeating: [Float](repeating: 0, count: Self.size), count: 5)
        ready = [[Float]](repeating: [Float](repeating: 0, count: Self.hop), count: 5)
    }

    // MARK: - 1 回分

    private func runFrame() {
        let size = Self.size
        let hop = Self.hop
        frameLeft.removeFirst(hop)
        frameLeft.append(contentsOf: pendingLeft.prefix(hop))
        frameRight.removeFirst(hop)
        frameRight.append(contentsOf: pendingRight.prefix(hop))
        pendingLeft.removeFirst(hop)
        pendingRight.removeFirst(hop)
        vDSP.multiply(frameLeft, window, result: &scratch.windowed)
        forward.transform(
            inputReal: scratch.windowed,
            inputImaginary: scratch.zeros,
            outputReal: &scratch.leftReal,
            outputImaginary: &scratch.leftImaginary
        )
        vDSP.multiply(frameRight, window, result: &scratch.windowed)
        forward.transform(
            inputReal: scratch.windowed,
            inputImaginary: scratch.zeros,
            outputReal: &scratch.rightReal,
            outputImaginary: &scratch.rightImaginary
        )
        separate()
        for channel in 0..<5 {
            inverse.transform(
                inputReal: scratch.outReal[channel],
                inputImaginary: scratch.outImaginary[channel],
                outputReal: &scratch.timeReal,
                outputImaginary: &scratch.timeImaginary
            )
            accumulators[channel].withUnsafeMutableBufferPointer { acc in
                for index in 0..<size {
                    acc[index] += scratch.timeReal[index] * window[index] * normalization
                }
            }
            ready[channel].append(contentsOf: accumulators[channel].prefix(hop))
            accumulators[channel].removeFirst(hop)
            accumulators[channel].append(contentsOf: repeatElement(0, count: hop))
        }
    }

    /// 周波数ごとに L・R・C・Ls・Rs のスペクトルを作る（scratch.out に書く）
    private func separate() {
        let blend = 1 - smoothing
        let centerScale = ChannelMatrix.half * 2
        for bin in 0..<Self.size {
            let lr = scratch.leftReal[bin]
            let li = scratch.leftImaginary[bin]
            let rr = scratch.rightReal[bin]
            let ri = scratch.rightImaginary[bin]
            crossLL[bin] = smoothing * crossLL[bin] + blend * (lr * lr + li * li)
            crossRR[bin] = smoothing * crossRR[bin] + blend * (rr * rr + ri * ri)
            crossLRReal[bin] = smoothing * crossLRReal[bin] + blend * (lr * rr + li * ri)
            crossLRImaginary[bin] = smoothing * crossLRImaginary[bin] + blend * (li * rr - lr * ri)
            let weights = UpmixWeights(
                autoLeft: crossLL[bin],
                autoRight: crossRR[bin],
                crossMagnitude: (crossLRReal[bin] * crossLRReal[bin] + crossLRImaginary[bin] * crossLRImaginary[bin]).squareRoot(),
                centerAmount: centerAmount,
                ambienceAmount: ambienceAmount
            )
            let midReal = (lr + rr) / 2
            let midImaginary = (li + ri) / 2
            scratch.outReal[0][bin] = (lr - weights.center * midReal) * weights.front
            scratch.outImaginary[0][bin] = (li - weights.center * midImaginary) * weights.front
            scratch.outReal[1][bin] = (rr - weights.center * midReal) * weights.front
            scratch.outImaginary[1][bin] = (ri - weights.center * midImaginary) * weights.front
            scratch.outReal[2][bin] = weights.center * midReal * centerScale
            scratch.outImaginary[2][bin] = weights.center * midImaginary * centerScale
            scratch.outReal[3][bin] = lr * weights.ambience
            scratch.outImaginary[3][bin] = li * weights.ambience
            scratch.outReal[4][bin] = rr * weights.ambience
            scratch.outImaginary[4][bin] = ri * weights.ambience
        }
    }
}

/// アップミックスの作業領域（クラスにして、変換の入力と出力を別々のプロパティとして同時に触れるようにする）
final class UpmixScratch {
    var windowed: [Float]
    let zeros: [Float]
    var leftReal: [Float]
    var leftImaginary: [Float]
    var rightReal: [Float]
    var rightImaginary: [Float]
    var outReal: [[Float]]
    var outImaginary: [[Float]]
    var timeReal: [Float]
    var timeImaginary: [Float]

    init(size: Int) {
        let empty = [Float](repeating: 0, count: size)
        windowed = empty
        zeros = empty
        leftReal = empty
        leftImaginary = empty
        rightReal = empty
        rightImaginary = empty
        outReal = [[Float]](repeating: empty, count: 5)
        outImaginary = [[Float]](repeating: empty, count: 5)
        timeReal = empty
        timeImaginary = empty
    }
}

/// 周波数ごとの振り分けの重み
struct UpmixWeights {
    /// センターに分ける割合（左右の和の半分に掛ける）
    let center: Float
    /// サラウンドに分ける割合
    let ambience: Float
    /// 左右に残す分の倍率（サラウンドに分けた分の力を引く）
    let front: Float

    init(autoLeft: Float, autoRight: Float, crossMagnitude: Float, centerAmount: Float, ambienceAmount: Float) {
        let total = autoLeft + autoRight + 1e-12
        let coherence = min(1, crossMagnitude / ((autoLeft * autoRight).squareRoot() + 1e-12))
        let panning = (autoLeft - autoRight) / total
        center = centerAmount * coherence * coherence * max(0, 1 - abs(panning) * 1.5)
        ambience = ambienceAmount * (1 - coherence).squareRoot()
        front = (max(0, 1 - 0.5 * ambience * ambience)).squareRoot()
    }
}
