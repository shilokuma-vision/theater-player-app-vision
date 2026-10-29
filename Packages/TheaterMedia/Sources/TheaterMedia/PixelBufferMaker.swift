//
//  PixelBufferMaker.swift
//  TheaterMedia
//
//  ソフトウェアでデコードしたフレーム（yuv420p・yuv422p10・rgb24 など）を、表示に渡せる CVPixelBuffer にする。
//  8 bit の YUV → NV12、10 bit 以上の YUV → P010、RGB → BGRA。色の情報（BT.709・BT.2020・PQ・HLG・範囲）は添付で付ける。
//

import CFFmpeg
import CoreVideo
import Foundation

final class PixelBufferMaker {
    private struct Key: Equatable {
        let width: Int32
        let height: Int32
        let source: Int32
        let target: OSType
    }

    private var key: Key?
    private var pool: CVPixelBufferPool?
    private var scaler: UnsafeMutablePointer<SwsContext>?

    deinit {
        sws_freeContext(scaler)
    }

    /// frame を CVPixelBuffer にする（色の添付を付ける）
    func make(from frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = frame.pointee.width
        let height = frame.pointee.height
        let source = frame.pointee.format
        let output = Self.outputFormat(for: AVPixelFormat(rawValue: source), fullRange: frame.pointee.color_range == AVCOL_RANGE_JPEG)
        let newKey = Key(width: width, height: height, source: source, target: output.pixelFormat)
        if newKey != key {
            guard prepare(newKey, output: output.ffmpeg, frame: frame) else {
                return nil
            }
            key = newKey
        }
        guard let pool else {
            return nil
        }
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let buffer = created else {
            return nil
        }
        guard scale(frame, into: buffer) else {
            return nil
        }
        av_vt_pixbuf_set_attachments(nil, buffer, frame)
        return buffer
    }

    /// 出力の形式（CoreVideo と FFmpeg）
    static func outputFormat(for source: AVPixelFormat, fullRange: Bool) -> (pixelFormat: OSType, ffmpeg: AVPixelFormat) {
        guard let descriptor = av_pix_fmt_desc_get(source) else {
            return (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, AV_PIX_FMT_NV12)
        }
        let flags = descriptor.pointee.flags
        if flags & UInt64(AV_PIX_FMT_FLAG_RGB) != 0 {
            return (kCVPixelFormatType_32BGRA, AV_PIX_FMT_BGRA)
        }
        if descriptor.pointee.comp.0.depth > 8 {
            let format = fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            return (format, AV_PIX_FMT_P010LE)
        }
        let format = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return (format, AV_PIX_FMT_NV12)
    }

    private func prepare(_ key: Key, output: AVPixelFormat, frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        sws_freeContext(scaler)
        scaler = sws_getContext(
            key.width,
            key.height,
            AVPixelFormat(rawValue: key.source),
            key.width,
            key.height,
            output,
            Int32(SWS_BICUBIC.rawValue),
            nil,
            nil,
            nil
        )
        guard let scaler else {
            return false
        }
        // YUV どうしでは範囲を変えない（変換の行列は表示の側で、添付の色の情報から選ぶ）
        let fullRange: Int32 = frame.pointee.color_range == AVCOL_RANGE_JPEG ? 1 : 0
        let coefficients = sws_getCoefficients(Int32(SWS_CS_DEFAULT))
        sws_setColorspaceDetails(scaler, coefficients, fullRange, coefficients, fullRange, 0, 1 << 16, 1 << 16)
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: key.target,
            kCVPixelBufferWidthKey: Int(key.width),
            kCVPixelBufferHeightKey: Int(key.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attributes as CFDictionary, &created)
        pool = created
        return created != nil
    }

    private func scale(_ frame: UnsafeMutablePointer<AVFrame>, into buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        var planes = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 4)
        var strides = [Int32](repeating: 0, count: 4)
        if CVPixelBufferIsPlanar(buffer) {
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                planes[plane] = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)?.assumingMemoryBound(to: UInt8.self)
                strides[plane] = Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, plane))
            }
        } else {
            planes[0] = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
            strides[0] = Int32(CVPixelBufferGetBytesPerRow(buffer))
        }
        let source = FrameArrays(frame)
        let rows = sws_scale(scaler, source.data, source.linesize, 0, frame.pointee.height, planes, strides)
        return rows > 0
    }
}

/// AVFrame の data・linesize（C の固定長の配列）を、ポインターとして読む
struct FrameArrays {
    let data: UnsafePointer<UnsafePointer<UInt8>?>
    let linesize: UnsafePointer<Int32>

    init(_ frame: UnsafeMutablePointer<AVFrame>) {
        let base = UnsafeMutableRawPointer(frame)
        data = UnsafePointer(base.advanced(by: MemoryLayout<AVFrame>.offset(of: \AVFrame.data) ?? 0)
            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self))
        linesize = UnsafePointer(base.advanced(by: MemoryLayout<AVFrame>.offset(of: \AVFrame.linesize) ?? 0)
            .assumingMemoryBound(to: Int32.self))
    }
}
