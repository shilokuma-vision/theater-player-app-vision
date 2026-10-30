//
//  DepthStereo.swift
//  StereoKit
//
//  深度（近いほど大きい相対的な値）から、左右の目の絵を作る（DIBR：深度に応じて画素を横にずらす）。
//  - 深度は毎コマの散らばり（2〜98 % の範囲）で 0〜1 にそろえる。範囲はコマをまたいでならし、明るさのようにちらつかないようにする
//  - 左右の目に半分ずつずらす（片目だけずらすより、ゆがみが目立たない）。収束の深さより近い物は手前に、遠い物は奥に見える
//

import Foundation

/// 立体の強さ
public struct StereoParameters: Sendable {
    /// いちばん近い物といちばん遠い物の、左右のずれの差（絵の幅に対する割合）。大きいほど立体感が強い
    public var strength: Float = 0.03
    /// 画面の面に見える深さ（0 が最も遠く、1 が最も近い）。これより近い物は画面から飛び出す
    public var convergence: Float = 0.35
    /// 深度の範囲をコマをまたいでならす強さ（0〜1。大きいほどゆっくり変わる）
    public var smoothing: Float = 0.85

    public init(strength: Float = 0.03, convergence: Float = 0.35, smoothing: Float = 0.85) {
        self.strength = strength
        self.convergence = convergence
        self.smoothing = smoothing
    }
}

/// 深度を 0〜1（1 が近い）にそろえる。範囲はコマをまたいでならす
public final class DepthNormalizer {
    private let smoothing: Float
    private var low: Float?
    private var high: Float?

    public init(smoothing: Float) {
        self.smoothing = smoothing
    }

    public func normalize(_ depth: [Float]) -> [Float] {
        let sorted = depth.sorted()
        guard let first = sorted.first, let last = sorted.last else {
            return depth
        }
        let frameLow = sorted[Int(Float(sorted.count - 1) * 0.02)]
        let frameHigh = sorted[Int(Float(sorted.count - 1) * 0.98)]
        let blend = { (previous: Float?, current: Float) -> Float in
            previous.map { $0 * self.smoothing + current * (1 - self.smoothing) } ?? current
        }
        low = blend(low, frameLow)
        high = blend(high, frameHigh)
        let range = max((high ?? last) - (low ?? first), 1e-6)
        let base = low ?? first
        return depth.map { min(max(($0 - base) / range, 0), 1) }
    }
}

/// 深度の画像を、別の大きさへ線形に引き伸ばす
public enum DepthResampler {
    public static func resample(_ depth: [Float], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [Float] {
        var result = [Float](repeating: 0, count: toWidth * toHeight)
        let scaleX = Float(width) / Float(toWidth)
        let scaleY = Float(height) / Float(toHeight)
        depth.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { target in
                // 行ごとに別の場所へ書くので、並列に使ってよい
                guard let sourceBase = source.baseAddress, let targetBase = target.baseAddress else {
                    return
                }
                nonisolated(unsafe) let source = sourceBase
                nonisolated(unsafe) let target = targetBase
                DispatchQueue.concurrentPerform(iterations: toHeight) { row in
                    let sourceY = min(max((Float(row) + 0.5) * scaleY - 0.5, 0), Float(height - 1))
                    let top = source + Int(sourceY) * width
                    let bottom = source + min(Int(sourceY) + 1, height - 1) * width
                    let weightY = sourceY - Float(Int(sourceY))
                    for column in 0..<toWidth {
                        let sourceX = min(max((Float(column) + 0.5) * scaleX - 0.5, 0), Float(width - 1))
                        let x0 = Int(sourceX)
                        let x1 = min(x0 + 1, width - 1)
                        let weightX = sourceX - Float(x0)
                        let upper = top[x0] * (1 - weightX) + top[x1] * weightX
                        let lower = bottom[x0] * (1 - weightX) + bottom[x1] * weightX
                        target[row * toWidth + column] = upper * (1 - weightY) + lower * weightY
                    }
                }
            }
        }
        return result
    }
}

/// 元の絵（画素は 32 bit の BGRA。stride は 1 行の画素数で、行末の余白を含む）
public struct SourceImage {
    public let base: UnsafePointer<UInt32>
    public let stride: Int
    public let width: Int
    public let height: Int

    public init(base: UnsafePointer<UInt32>, stride: Int, width: Int, height: Int) {
        self.base = base
        self.stride = stride
        self.width = width
        self.height = height
    }
}

/// 左右の目の絵の書き先（同じバッファの左半分・右半分でもよい。大きさは元の絵と同じ）
public struct StereoTarget {
    public let left: UnsafeMutablePointer<UInt32>
    public let right: UnsafeMutablePointer<UInt32>
    public let stride: Int

    public init(left: UnsafeMutablePointer<UInt32>, right: UnsafeMutablePointer<UInt32>, stride: Int) {
        self.left = left
        self.right = right
        self.stride = stride
    }
}

/// 左右の目の絵を作る
public enum StereoWarp {
    /// 深度 depth（0〜1、1 が近い）の、左目の絵の画素のずれ（右目は逆向き）。近い物ほど左目では右へ、右目では左へずれる
    @inline(__always)
    public static func shift(depth: Float, width: Int, parameters: StereoParameters) -> Float {
        (depth - parameters.convergence) * parameters.strength * Float(width) / 2
    }

    /// source から、左右の目の絵を target に書く。depth は元の絵と同じ大きさ。
    /// 各画素は、ずらした先の深度で 2 回たどり直して元の位置を探す（後ろからたどるので穴は出ない。見えてきた背景は引き伸ばされる）
    public static func render(_ source: SourceImage, depth: [Float], into target: StereoTarget, parameters: StereoParameters) {
        let width = source.width
        depth.withUnsafeBufferPointer { depthBuffer in
            guard let depthBuffer = depthBuffer.baseAddress else {
                return
            }
            // 行ごとに別の場所へ書くので、並列に使ってよい
            nonisolated(unsafe) let (source, depthBase, target) = (source, depthBuffer, target)
            DispatchQueue.concurrentPerform(iterations: source.height) { row in
                let sourceRow = source.base + row * source.stride
                let depthRow = depthBase + row * width
                let leftRow = target.left + row * target.stride
                let rightRow = target.right + row * target.stride
                for column in 0..<width {
                    leftRow[column] = sourceRow[sourceColumn(column, eye: 1, depthRow: depthRow, width: width, parameters: parameters)]
                    rightRow[column] = sourceRow[sourceColumn(column, eye: -1, depthRow: depthRow, width: width, parameters: parameters)]
                }
            }
        }
    }

    /// 目の絵の column 列に映る、元の絵の列（eye は左目が 1、右目が -1）
    @inline(__always)
    private static func sourceColumn(
        _ column: Int,
        eye: Float,
        depthRow: UnsafePointer<Float>,
        width: Int,
        parameters: StereoParameters
    ) -> Int {
        var position = Float(column)
        for _ in 0..<2 {
            let sample = min(max(Int(position.rounded()), 0), width - 1)
            position = Float(column) - eye * shift(depth: depthRow[sample], width: width, parameters: parameters)
        }
        return min(max(Int(position.rounded()), 0), width - 1)
    }
}
