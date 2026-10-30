//
//  SideBySideComposer.swift
//  TheaterMedia
//
//  3D の映像を、左右に並べた 1 枚のフレーム（左が左目）にする。平面ごとに行を写す。
//  RealityKit の VideoMaterial は、左右に並べたフレームなら実機でも立体に映すが、上下に並べたフレーム（OverUnder の指定）は
//  立体に映らなかった。上下に並べた映像と、左右が別の層の空間ビデオは、ここで左右に並べ替えてから渡す
//

import CoreVideo
import Foundation

final class SideBySideComposer {
    private struct Key: Equatable {
        let width: Int
        let height: Int
        let format: OSType
    }

    /// 写す元：buffer の band 段目（上下に並べたフレームなら 0 が上・1 が下。1 枚の絵なら 0）
    private struct Source {
        let buffer: CVPixelBuffer
        let band: Int
    }

    private var pool: CVPixelBufferPool?
    private var poolKey: Key?

    /// 上下に並べたフレーム（上が左目）を、左右に並べたフレームにする
    func sideBySide(fromOverUnder frame: CVPixelBuffer) -> CVPixelBuffer? {
        compose(
            [Source(buffer: frame, band: 0), Source(buffer: frame, band: 1)],
            eyeWidth: CVPixelBufferGetWidth(frame),
            eyeHeight: CVPixelBufferGetHeight(frame) / 2
        )
    }

    /// 同じ大きさの左目・右目の 2 枚を、左右に並べた 1 枚にする（空間ビデオ）
    func sideBySide(left: CVPixelBuffer, right: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(left)
        let height = CVPixelBufferGetHeight(left)
        guard CVPixelBufferGetWidth(right) == width, CVPixelBufferGetHeight(right) == height,
              CVPixelBufferGetPixelFormatType(right) == CVPixelBufferGetPixelFormatType(left) else {
            return nil
        }
        return compose([Source(buffer: left, band: 0), Source(buffer: right, band: 0)], eyeWidth: width, eyeHeight: height)
    }

    /// 平面ごとの、1 つの要素（輝度 1 つ・色差の組 1 つ・BGRA の 1 画素）のバイト数
    static func bytesPerElement(_ format: OSType) -> [Int]? {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
            [1, 2]
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            [2, 4]
        case kCVPixelFormatType_32BGRA:
            [4]
        default:
            nil
        }
    }

    /// sources[0] を左半分、sources[1] を右半分に写した、新しいバッファ
    private func compose(_ sources: [Source], eyeWidth: Int, eyeHeight: Int) -> CVPixelBuffer? {
        guard let first = sources.first else {
            return nil
        }
        let key = Key(width: eyeWidth * 2, height: eyeHeight, format: CVPixelBufferGetPixelFormatType(first.buffer))
        guard eyeWidth >= 2, eyeHeight >= 2, let elements = Self.bytesPerElement(key.format), let pool = pool(for: key) else {
            return nil
        }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let target = made else {
            return nil
        }
        CVPixelBufferLockBaseAddress(target, [])
        defer {
            CVPixelBufferUnlockBaseAddress(target, [])
        }
        for (side, source) in sources.enumerated() {
            CVPixelBufferLockBaseAddress(source.buffer, .readOnly)
            defer {
                CVPixelBufferUnlockBaseAddress(source.buffer, .readOnly)
            }
            guard copy(source, into: target, side: side, elements: elements) else {
                return nil
            }
        }
        // 色の情報（色域・伝達特性・行列）を引き継ぐ
        CVBufferPropagateAttachments(first.buffer, target)
        return target
    }

    /// source を target の左半分（side 0）か右半分（side 1）に写す
    private func copy(_ source: Source, into target: CVPixelBuffer, side: Int, elements: [Int]) -> Bool {
        let isPlanar = CVPixelBufferIsPlanar(target)
        for plane in 0..<elements.count {
            let from = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(source.buffer, plane) : CVPixelBufferGetBaseAddress(source.buffer)
            let into = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(target, plane) : CVPixelBufferGetBaseAddress(target)
            guard let from, let into else {
                return false
            }
            let sourceRow = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(source.buffer, plane) : CVPixelBufferGetBytesPerRow(source.buffer)
            let targetRow = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(target, plane) : CVPixelBufferGetBytesPerRow(target)
            let rows = isPlanar ? CVPixelBufferGetHeightOfPlane(target, plane) : CVPixelBufferGetHeight(target)
            let width = isPlanar ? CVPixelBufferGetWidthOfPlane(target, plane) : CVPixelBufferGetWidth(target)
            // 片目ぶんの 1 行のバイト数
            let bytes = min(width / 2 * elements[plane], sourceRow)
            let start = from + source.band * rows * sourceRow
            for row in 0..<rows {
                memcpy(into + row * targetRow + side * bytes, start + row * sourceRow, bytes)
            }
        }
        return true
    }

    private func pool(for key: Key) -> CVPixelBufferPool? {
        if key == poolKey, let pool {
            return pool
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: key.format,
            kCVPixelBufferWidthKey as String: key.width,
            kCVPixelBufferHeightKey as String: key.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
        pool = created
        poolKey = created == nil ? nil : key
        return created
    }
}
