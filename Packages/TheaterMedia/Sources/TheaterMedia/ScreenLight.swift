//
//  ScreenLight.swift
//  TheaterMedia
//
//  スクリーンの光：映像の左・中央・右の 3 つの区画の平均の色（リニア、1 = SDR の白）。
//  映画館の部屋がスクリーンの光で照らされる（座席・壁にスクリーンの色が映る）のに使う。
//  CVPixelBuffer の画素を粗い格子（24 × 12 点）で読み、YUV → RGB（BT.601 / 709 / 2020）・PQ / HLG を戻して平均する。
//

import CoreVideo
import Foundation
import simd

/// 3 つの区画の光
public struct ScreenLight: Sendable, Equatable {
    public var left: SIMD3<Float>
    public var center: SIMD3<Float>
    public var right: SIMD3<Float>

    public static let black = ScreenLight(left: .zero, center: .zero, right: .zero)

    public var average: SIMD3<Float> {
        (left + center + right) / 3
    }
}

enum ScreenLightSampler {
    static let columns = 24
    static let rows = 12

    /// 色の行列（Y'CbCr → R'G'B' の Kr・Kb）
    struct Matrix {
        let kr: Float
        let kb: Float

        static let bt601 = Matrix(kr: 0.299, kb: 0.114)
        static let bt709 = Matrix(kr: 0.2126, kb: 0.0722)
        static let bt2020 = Matrix(kr: 0.2627, kb: 0.0593)
    }

    static func sample(_ buffer: CVPixelBuffer) -> ScreenLight {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return .black
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let decode = decoder(for: attachment(buffer, kCVImageBufferTransferFunctionKey))
        var sums = [SIMD3<Float>](repeating: .zero, count: 3)
        var counts = [Float](repeating: 0, count: 3)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        for row in 0..<rows {
            let y = (row * 2 + 1) * height / (rows * 2)
            for column in 0..<columns {
                let x = (column * 2 + 1) * width / (columns * 2)
                guard let rgb = pixel(buffer, format: format, x: x, y: y) else {
                    continue
                }
                let zone = column * 3 / columns
                sums[zone] += decode(simd_clamp(rgb, .zero, SIMD3(repeating: 1)))
                counts[zone] += 1
            }
        }
        let zones = (0..<3).map { counts[$0] > 0 ? sums[$0] / counts[$0] : .zero }
        return ScreenLight(left: zones[0], center: zones[1], right: zones[2])
    }

    /// 1 画素の R'G'B'（0〜1、ガンマのかかった値）
    static func pixel(_ buffer: CVPixelBuffer, format: OSType, x: Int, y: Int) -> SIMD3<Float>? {
        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let pointer = base + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            return SIMD3(Float(pointer[2]), Float(pointer[1]), Float(pointer[0])) / 255
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return biplanar(buffer, x: x, y: y, bits: 8, fullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return biplanar(buffer, x: x, y: y, bits: 10, fullRange: format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        default:
            return nil
        }
    }

    private static func biplanar(_ buffer: CVPixelBuffer, x: Int, y: Int, bits: Int, fullRange: Bool) -> SIMD3<Float>? {
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            return nil
        }
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let values: SIMD3<Float>
        if bits == 8 {
            let yValue = luma.load(fromByteOffset: y * lumaRow + x, as: UInt8.self)
            let cb = chroma.load(fromByteOffset: (y / 2) * chromaRow + (x / 2) * 2, as: UInt8.self)
            let cr = chroma.load(fromByteOffset: (y / 2) * chromaRow + (x / 2) * 2 + 1, as: UInt8.self)
            values = SIMD3(Float(yValue), Float(cb), Float(cr)) / 255
        } else {
            // P010：上位 10 bit に値がある 16 bit
            let yValue = luma.load(fromByteOffset: y * lumaRow + x * 2, as: UInt16.self)
            let cb = chroma.load(fromByteOffset: (y / 2) * chromaRow + (x / 2) * 4, as: UInt16.self)
            let cr = chroma.load(fromByteOffset: (y / 2) * chromaRow + (x / 2) * 4 + 2, as: UInt16.self)
            values = SIMD3(Float(yValue), Float(cb), Float(cr)) / 65_535
        }
        return toRGB(values, matrix: matrix(of: buffer), fullRange: fullRange)
    }

    static func toRGB(_ ycbcr: SIMD3<Float>, matrix: Matrix, fullRange: Bool) -> SIMD3<Float> {
        let luma = fullRange ? ycbcr.x : (ycbcr.x - 16 / 255) * 255 / 219
        let cb = (fullRange ? ycbcr.y - 0.5 : (ycbcr.y - 128 / 255) * 255 / 224)
        let cr = (fullRange ? ycbcr.z - 0.5 : (ycbcr.z - 128 / 255) * 255 / 224)
        let kg = 1 - matrix.kr - matrix.kb
        let red = luma + 2 * (1 - matrix.kr) * cr
        let blue = luma + 2 * (1 - matrix.kb) * cb
        let green = (luma - matrix.kr * red - matrix.kb * blue) / kg
        return SIMD3(red, green, blue)
    }

    static func matrix(of buffer: CVPixelBuffer) -> Matrix {
        let value = attachment(buffer, kCVImageBufferYCbCrMatrixKey)
        if value == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String {
            return .bt2020
        }
        if value == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String {
            return .bt601
        }
        return .bt709
    }

    /// 伝達関数（PQ・HLG・ふつうのガンマ）に合わせた、リニアに戻す関数
    static func decoder(for transfer: String?) -> (SIMD3<Float>) -> SIMD3<Float> {
        if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String {
            return pqToLinear
        }
        if transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
            return hlgToLinear
        }
        return gammaToLinear
    }

    static func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> String? {
        CVBufferCopyAttachment(buffer, key, nil) as? String
    }

    static func gammaToLinear(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(pow(value.x, 2.2), pow(value.y, 2.2), pow(value.z, 2.2))
    }

    /// PQ（SMPTE ST 2084）→ リニア。SDR の白（100 nit）を 1 にする
    static func pqToLinear(_ value: SIMD3<Float>) -> SIMD3<Float> {
        func channel(_ encoded: Float) -> Float {
            let m1: Float = 0.159_301_76
            let m2: Float = 78.843_75
            let c1: Float = 0.835_937_5
            let c2: Float = 18.851_562
            let c3: Float = 18.687_5
            let power = pow(max(encoded, 0), 1 / m2)
            let nits = 10_000 * pow(max(power - c1, 0) / (c2 - c3 * power), 1 / m1)
            return nits / 100
        }
        return SIMD3(channel(value.x), channel(value.y), channel(value.z))
    }

    /// HLG → リニア（シーンの光。白 = 1 の近く）
    static func hlgToLinear(_ value: SIMD3<Float>) -> SIMD3<Float> {
        func channel(_ encoded: Float) -> Float {
            encoded <= 0.5 ? encoded * encoded / 3 : (exp((encoded - 0.559_910_7) / 0.178_832_77) + 0.284_668_92) / 12
        }
        return SIMD3(channel(value.x), channel(value.y), channel(value.z)) * 3.7
    }
}

/// 表示した（する）フレームのスクリーンの光の記録。描画の時刻に合わせて引く
final class ScreenLightTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(time: Double, light: ScreenLight)] = []

    func append(time: Double, light: ScreenLight) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((time, light))
        if entries.count > 48 {
            entries.removeFirst(entries.count - 48)
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    /// time より前でいちばん新しいフレームの光
    func light(at time: Double) -> ScreenLight? {
        lock.lock()
        defer { lock.unlock() }
        return entries.last { $0.time <= time + 0.001 }?.light ?? entries.first?.light
    }
}
