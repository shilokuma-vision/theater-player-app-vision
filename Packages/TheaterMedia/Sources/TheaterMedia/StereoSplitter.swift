//
//  StereoSplitter.swift
//  TheaterMedia
//
//  左右・上下に並べた 3D のフレームを、左目・右目の 2 枚の画素のバッファに切り分ける（平面ごとに行を写す）。
//  左目は左（上）。ハーフ（片目を半分に縮めたもの）も、そのまま半分の大きさで切り出す（スクリーンの形で縦横比を合わせる）
//

import CoreVideo
import Foundation

final class StereoSplitter {
    private struct Key: Equatable {
        let width: Int
        let height: Int
        let format: OSType
    }

    private var pool: CVPixelBufferPool?
    private var poolKey: Key?

    /// frame を packing（左右・上下）で切り分ける。切り分けられない（形式が分からない・小さすぎる）なら nil
    func split(_ frame: CVPixelBuffer, packing: StereoPacking) -> (left: CVPixelBuffer, right: CVPixelBuffer)? {
        let isSideBySide = packing == .sideBySide
        guard isSideBySide || packing == .overUnder else {
            return nil
        }
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        let key = Key(
            width: isSideBySide ? width / 2 : width,
            height: isSideBySide ? height : height / 2,
            format: CVPixelBufferGetPixelFormatType(frame)
        )
        guard key.width >= 2, key.height >= 2, let elements = Self.bytesPerElement(key.format), let pool = pool(for: key) else {
            return nil
        }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        guard let left = copy(frame, eye: 0, isSideBySide: isSideBySide, elements: elements, pool: pool),
              let right = copy(frame, eye: 1, isSideBySide: isSideBySide, elements: elements, pool: pool) else {
            return nil
        }
        return (left, right)
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

    /// frame の片目（eye：0 が左・上、1 が右・下）を、pool の新しいバッファに写す
    private func copy(
        _ frame: CVPixelBuffer,
        eye: Int,
        isSideBySide: Bool,
        elements: [Int],
        pool: CVPixelBufferPool
    ) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let target = made else {
            return nil
        }
        CVPixelBufferLockBaseAddress(target, [])
        defer {
            CVPixelBufferUnlockBaseAddress(target, [])
        }
        let isPlanar = CVPixelBufferIsPlanar(frame)
        for plane in 0..<elements.count {
            let source = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(frame, plane) : CVPixelBufferGetBaseAddress(frame)
            let destination = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(target, plane) : CVPixelBufferGetBaseAddress(target)
            guard let source, let destination else {
                return nil
            }
            let sourceRow = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(frame, plane) : CVPixelBufferGetBytesPerRow(frame)
            let targetRow = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(target, plane) : CVPixelBufferGetBytesPerRow(target)
            let rows = isPlanar ? CVPixelBufferGetHeightOfPlane(target, plane) : CVPixelBufferGetHeight(target)
            let width = isPlanar ? CVPixelBufferGetWidthOfPlane(target, plane) : CVPixelBufferGetWidth(target)
            let bytes = min(width * elements[plane], targetRow)
            // 左右なら行の右半分から、上下なら下半分の行から写す
            let offset = isSideBySide ? eye * bytes : eye * rows * sourceRow
            for row in 0..<rows {
                memcpy(destination + row * targetRow, source + offset + row * sourceRow, bytes)
            }
        }
        // 色の情報（色域・伝達特性・行列）を引き継ぐ
        CVBufferPropagateAttachments(frame, target)
        return target
    }
}
