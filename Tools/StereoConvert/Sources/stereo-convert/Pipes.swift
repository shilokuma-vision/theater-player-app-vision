//
//  Pipes.swift
//  stereo-convert
//
//  読み出しから書き出しまでの流れ（映像・音声で別々の AVAssetReader を使う。
//  1 つの読み出しから両方を取ると、片方を読まない間にもう片方が止まり、書き出しの待ちと組み合わさって動かなくなることがある）。
//

import AVFoundation
import Foundation
import StereoKit

/// 映像：コマを読み、深度から左右の目の絵を作り、左右に並べて書く
final class VideoPipe {
    let input: AVAssetWriterInput
    let width: Int
    let height: Int
    private(set) var frames = 0
    private let reader: AVAssetReader
    private let output: AVAssetReaderVideoCompositionOutput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let estimator: DepthEstimator
    private let normalizer: DepthNormalizer
    private let parameters: StereoParameters

    /// composition は回転などを当てた表示の向きで読むためのもの。range は変換する範囲
    init(
        asset: AVURLAsset,
        tracks: [AVAssetTrack],
        composition: AVVideoComposition,
        range: CMTimeRange?,
        writer: AVAssetWriter,
        settings: [String: Any],
        estimator: DepthEstimator,
        parameters: StereoParameters
    ) throws {
        width = Int(composition.renderSize.width)
        height = Int(composition.renderSize.height)
        reader = try AVAssetReader(asset: asset)
        if let range {
            reader.timeRange = range
        }
        output = AVAssetReaderVideoCompositionOutput(
            videoTracks: tracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width * 2,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
        )
        writer.add(input)
        self.estimator = estimator
        self.parameters = parameters
        normalizer = DepthNormalizer(smoothing: parameters.smoothing)
    }

    func start() throws {
        guard reader.startReading() else {
            throw ConvertError.failed("映像を読めません：\(reader.error?.localizedDescription ?? "")")
        }
    }

    /// 1 コマ変換して書く。読み終わったら false
    func step() throws -> Bool {
        try autoreleasepool {
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    throw ConvertError.failed("映像を読めません：\(reader.error?.localizedDescription ?? "")")
                }
                input.markAsFinished()
                return false
            }
            guard let frame = CMSampleBufferGetImageBuffer(sample) else {
                return true
            }
            var made: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            }
            guard let buffer = made else {
                throw ConvertError.failed("書き出す画像を作れません")
            }
            try convert(frame, into: buffer)
            guard adaptor.append(buffer, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sample)) else {
                throw ConvertError.failed("映像を書けません")
            }
            frames += 1
            return true
        }
    }

    /// frame（BGRA）から左右の目の絵を作り、buffer（幅が 2 倍の BGRA）の左半分・右半分に書く
    private func convert(_ frame: CVPixelBuffer, into buffer: CVPixelBuffer) throws {
        let depth = DepthResampler.resample(
            normalizer.normalize(try estimator.depth(of: frame)),
            width: estimator.inputWidth,
            height: estimator.inputHeight,
            toWidth: width,
            toHeight: height
        )
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        guard let source = CVPixelBufferGetBaseAddress(frame), let target = CVPixelBufferGetBaseAddress(buffer),
              CVPixelBufferGetWidth(frame) == width, CVPixelBufferGetHeight(frame) == height else {
            throw ConvertError.failed("コマの大きさが途中で変わりました")
        }
        let left = target.assumingMemoryBound(to: UInt32.self)
        StereoWarp.render(
            SourceImage(
                base: source.assumingMemoryBound(to: UInt32.self),
                stride: CVPixelBufferGetBytesPerRow(frame) / 4,
                width: width,
                height: height
            ),
            depth: depth,
            into: StereoTarget(left: left, right: left + width, stride: CVPixelBufferGetBytesPerRow(buffer) / 4),
            parameters: parameters
        )
    }
}

/// 音声：そのまま写す（入れ物に入らない形式なら AAC にする）
final class AudioPipe {
    let input: AVAssetWriterInput
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    init?(asset: AVURLAsset, range: CMTimeRange?, writer: AVAssetWriter) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        let hint = try await track.load(.formatDescriptions).first
        reader = try AVAssetReader(asset: asset)
        if let range {
            reader.timeRange = range
        }
        let passthrough = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
        if writer.canAdd(passthrough) {
            output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            input = passthrough
        } else {
            output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48_000]
            )
            input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 48_000,
                    AVEncoderBitRateKey: 256_000
                ]
            )
        }
        output.alwaysCopiesSampleData = false
        reader.add(output)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
    }

    func start() throws {
        guard reader.startReading() else {
            throw ConvertError.failed("音声を読めません：\(reader.error?.localizedDescription ?? "")")
        }
    }

    /// 1 つ写す。読み終わったら false
    func step() throws -> Bool {
        guard let sample = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw ConvertError.failed("音声を読めません：\(reader.error?.localizedDescription ?? "")")
            }
            input.markAsFinished()
            return false
        }
        guard input.append(sample) else {
            throw ConvertError.failed("音声を書けません")
        }
        return true
    }
}
