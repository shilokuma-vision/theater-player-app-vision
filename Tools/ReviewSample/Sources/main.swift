//
//  main.swift
//  ReviewSample
//
//  App Review の担当者に渡すサンプルの動画を作る（外部の素材を使わない。絵も音もこのコードが作る）。
//  1920 × 1080・24 fps の H.264、48 kHz・5.1 の AAC、チャプター（Nero 形式）付きの QuickTime（.mov）。使い方は Tools/ReviewSample/README.md
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "TheaterPlayer-Sample.mov")
try? FileManager.default.removeItem(at: output)

let frameRate = 24
let audioChunk = 4_800
let channelCount = Speaker.allCases.count

// MARK: - 書き出しの準備

let writer = try AVAssetWriter(outputURL: output, fileType: .mov)

let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Picture.width,
    AVVideoHeightKey: Picture.height,
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
    ],
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 5_000_000,
        AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoExpectedSourceFrameRateKey: frameRate
    ]
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: Picture.width,
    kCVPixelBufferHeightKey as String: Picture.height
])

/// チャンネルの並びの指定（AVChannelLayoutKey に渡す形）
func channelLayout(_ tag: AudioChannelLayoutTag) -> Data {
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = tag
    return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
}

// AAC は C・L・R・Ls・Rs・LFE の順（MPEG_5_1_D）で持つ。渡す PCM の並び（MPEG_5_1_A）から書き出しが並べ替える
let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: Sound.sampleRate,
    AVNumberOfChannelsKey: channelCount,
    AVEncoderBitRateKey: 384_000,
    AVChannelLayoutKey: channelLayout(kAudioChannelLayoutTag_MPEG_5_1_D)
])

var pcmDescription = AudioStreamBasicDescription(
    mSampleRate: Sound.sampleRate,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: UInt32(4 * channelCount),
    mFramesPerPacket: 1,
    mBytesPerFrame: UInt32(4 * channelCount),
    mChannelsPerFrame: UInt32(channelCount),
    mBitsPerChannel: 32,
    mReserved: 0
)
var pcmLayout = AudioChannelLayout()
pcmLayout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
var pcmFormat: CMAudioFormatDescription?
CMAudioFormatDescriptionCreate(
    allocator: nil,
    asbd: &pcmDescription,
    layoutSize: MemoryLayout<AudioChannelLayout>.size,
    layout: &pcmLayout,
    magicCookieSize: 0,
    magicCookie: nil,
    extensions: nil,
    formatDescriptionOut: &pcmFormat
)

for input in [videoInput, audioInput] {
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
        fatalError("\(input.mediaType.rawValue) のトラックを足せません")
    }
    writer.add(input)
}

// MARK: - 書き出し

/// start サンプル目から frames サンプルぶんの音
@MainActor
func audioBuffer(sound: inout Sound, start: Int, frames: Int) -> CMSampleBuffer? {
    var samples = [Float](repeating: 0, count: frames * channelCount)
    for frame in 0..<frames {
        let values = sound.frame(at: Double(start + frame) / Sound.sampleRate)
        for channel in 0..<channelCount {
            samples[frame * channelCount + channel] = Float(values[channel])
        }
    }
    let length = samples.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
        allocator: nil,
        memoryBlock: nil,
        blockLength: length,
        blockAllocator: nil,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: length,
        flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &block
    )
    guard let block, let pcmFormat else {
        return nil
    }
    samples.withUnsafeBytes { bytes in
        _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
    }
    var buffer: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil,
        dataBuffer: block,
        formatDescription: pcmFormat,
        sampleCount: frames,
        presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(Sound.sampleRate)),
        packetDescriptions: nil,
        sampleBufferOut: &buffer
    )
    return buffer
}

/// その時刻の絵
@MainActor
func pixelBuffer(picture: Picture, time: Double) -> CVPixelBuffer? {
    guard let pool = adaptor.pixelBufferPool else {
        return nil
    }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let buffer else {
        return nil
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: Picture.width,
        height: Picture.height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else {
        return nil
    }
    picture.draw(in: context, time: time)
    return buffer
}

writer.startWriting()
writer.startSession(atSourceTime: .zero)

let picture = Picture()
var sound = Sound()
let totalFrames = Int(Part.duration) * frameRate
let totalSamples = Int(Part.duration * Sound.sampleRate)
var writtenFrames = 0
var writtenSamples = 0

// 受け取れる入力から順に渡す。書き出しはトラックを交互に書くため、ほかのトラックが追いつくまで受け取らない入力がある
// （1 つの入力を待ち続けると止まる）
while writtenFrames < totalFrames || writtenSamples < totalSamples {
    var progressed = false
    if writtenSamples < totalSamples, audioInput.isReadyForMoreMediaData {
        let frames = min(audioChunk, totalSamples - writtenSamples)
        if let buffer = audioBuffer(sound: &sound, start: writtenSamples, frames: frames) {
            audioInput.append(buffer)
        }
        writtenSamples += frames
        if writtenSamples == totalSamples {
            audioInput.markAsFinished()
        }
        progressed = true
    }
    if writtenFrames < totalFrames, videoInput.isReadyForMoreMediaData {
        let time = Double(writtenFrames) / Double(frameRate)
        if let buffer = pixelBuffer(picture: picture, time: time) {
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(writtenFrames), timescale: CMTimeScale(frameRate)))
        }
        if writtenFrames.isMultiple(of: frameRate * 20) {
            print("\(Int(time)) / \(Int(Part.duration)) 秒")
        }
        writtenFrames += 1
        if writtenFrames == totalFrames {
            videoInput.markAsFinished()
        }
        progressed = true
    }
    if !progressed {
        guard writer.status != .failed else {
            fatalError("書き出しに失敗しました：\(writer.error?.localizedDescription ?? "不明")")
        }
        usleep(1_000)
    }
}

await writer.finishWriting()
guard writer.status == .completed else {
    fatalError("書き出しに失敗しました：\(writer.error?.localizedDescription ?? "不明")")
}

try Chapters.write(to: output)

// MARK: - 確かめる

let asset = AVURLAsset(url: output)
let duration = try await asset.load(.duration)
let tracks = try await asset.load(.tracks).map { $0.mediaType.rawValue }
let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
print("書き出しました：\(output.path)（\(String(format: "%.1f", duration.seconds)) 秒・\(size / 1_000_000) MB・トラック \(tracks)）")
for part in Part.allCases {
    print("  チャプター \(String(format: "%5.0f", part.start)) 秒：\(part.name)")
}
