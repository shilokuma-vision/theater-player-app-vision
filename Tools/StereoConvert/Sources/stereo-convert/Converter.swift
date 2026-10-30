//
//  Converter.swift
//  stereo-convert
//
//  2D の動画を、左右に並べた 3D の動画（フル SBS）に変換する。
//  映像は 1 コマずつ深度を推定して左右の目の絵を作り、音声はそのまま写す。
//  書き出しは映像と音声を交互に少しずつ渡す（片方だけ先に全部渡すと、書き出しが交互に並べるのを待って止まる）
//

import AVFoundation
import Foundation
import StereoKit

final class Converter {
    private let options: Options

    init(options: Options) {
        self.options = options
    }

    func run() async throws {
        let asset = AVURLAsset(url: options.input)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw ConvertError.noVideo
        }
        let composition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        let frameRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let seconds = options.seconds.map { min($0, duration) } ?? duration
        let range = options.seconds.map { CMTimeRange(start: .zero, duration: CMTime(seconds: $0, preferredTimescale: 600)) }

        try prepareOutput()
        let estimator = try await DepthEstimator(modelURL: options.model)
        let writer = try AVAssetWriter(outputURL: options.output, fileType: fileType)
        let video = try VideoPipe(
            asset: asset,
            tracks: tracks,
            composition: composition,
            range: range,
            writer: writer,
            settings: videoSettings(size: composition.renderSize, frameRate: frameRate),
            estimator: estimator,
            parameters: options.parameters
        )
        let audio = try await AudioPipe(asset: asset, range: range, writer: writer)
        log("変換します：\(video.width)×\(video.height) → \(video.width * 2)×\(video.height)（\(options.codec == .h264 ? "H.264" : "HEVC")）")

        try video.start()
        try audio?.start()
        guard writer.startWriting() else {
            throw ConvertError.failed("書き出せません：\(writer.error?.localizedDescription ?? "")")
        }
        writer.startSession(atSourceTime: .zero)
        let total = max(Int((seconds * Double(frameRate)).rounded()), 1)
        try await pump(video: video, audio: audio, writer: writer, total: total)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ConvertError.failed("書き出しに失敗しました：\(writer.error?.localizedDescription ?? "")")
        }
        log("\n書き出しました：\(options.output.path)")
    }

    /// 書き出しの準備ができた方へ渡す。どちらも待ちなら少し待つ
    private func pump(video: VideoPipe, audio: AudioPipe?, writer: AVAssetWriter, total: Int) async throws {
        var videoDone = false
        var audioDone = audio == nil
        let started = Date()
        var reported = Date.distantPast
        while !(videoDone && audioDone) {
            var progressed = false
            if !videoDone, video.input.isReadyForMoreMediaData {
                videoDone = try !video.step()
                progressed = true
            }
            if !audioDone, let audio, audio.input.isReadyForMoreMediaData {
                audioDone = try !audio.step()
                progressed = true
            }
            if writer.status == .failed {
                throw ConvertError.failed("書き出しに失敗しました：\(writer.error?.localizedDescription ?? "")")
            }
            if Date().timeIntervalSince(reported) >= 1 || videoDone && audioDone {
                reported = Date()
                report(frames: video.frames, total: total, elapsed: reported.timeIntervalSince(started))
            }
            if !progressed {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    private func report(frames: Int, total: Int, elapsed: TimeInterval) {
        let rate = Double(frames) / max(elapsed, 0.001)
        let remaining = rate > 0 ? Double(max(total - frames, 0)) / rate : 0
        let percent = min(Double(frames) / Double(total) * 100, 100)
        let line = String(
            format: "\r%5.1f %%  %d / %d コマ  %.1f コマ/秒  残り約 %d 分 %02d 秒   ",
            percent,
            frames,
            total,
            rate,
            Int(remaining) / 60,
            Int(remaining) % 60
        )
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private var fileType: AVFileType {
        switch options.output.pathExtension.lowercased() {
        case "mov":
            .mov
        case "m4v":
            .m4v
        default:
            .mp4
        }
    }

    private func prepareOutput() throws {
        guard FileManager.default.fileExists(atPath: options.output.path) else {
            return
        }
        guard options.overwrite else {
            throw ConvertError.failed("出力先にファイルがあります：\(options.output.path)（上書きするときは --overwrite）")
        }
        try FileManager.default.removeItem(at: options.output)
    }

    /// 書き出しの映像の設定（左右に並べるので幅は 2 倍。ビットレートは画素数とコマ数から決める）
    private func videoSettings(size: CGSize, frameRate: Float) throws -> [String: Any] {
        let width = Int(size.width) * 2
        let height = Int(size.height)
        let isHEVC = options.codec == .hevc
        let limit = isHEVC ? 8_192 : 4_096
        guard width <= limit else {
            throw ConvertError.tooWide(width, isHEVC ? "HEVC" : "H.264")
        }
        let fps = Double(frameRate > 0 ? frameRate : 30)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(Double(width * height) * fps * (isHEVC ? 0.08 : 0.12)),
            AVVideoExpectedSourceFrameRateKey: fps
        ]
        if !isHEVC {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        return [
            AVVideoCodecKey: options.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
    }
}
