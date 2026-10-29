//
//  VideoOutput.swift
//  TheaterMedia
//
//  映像の出口。デコードしたフレームを AVSampleBufferVideoRenderer に時刻付きで渡す。
//  RealityKit の VideoMaterial(videoRenderer:) がこの renderer をスクリーンに貼る。表示の時刻は AVSampleBufferRenderSynchronizer の
//  時計で決まり（フレームの間隔・HDR の表示はシステムが受け持つ）、音の時計に合わせてこの時計を動かす（MediaClock）。
//  3D の映像は、左目・右目の絵に印（タグ）を付けて 1 つのサンプルにまとめて渡す。
//  左右に並べたフレームのまま、形式に並べ方の指定（ViewPackingKind など）を付けて渡すと、実機（visionOS 27）では何も映らず、
//  その renderer はあとの 2D の映像も映さなくなった。3D と 2D を切り替えるときは renderer を作り直し、VideoMaterial を付け替える
//

@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// デコードしたフレーム
struct DecodedVideoFrame: @unchecked Sendable {
    /// 画素（3D なら左目の絵、または左右・上下に並べたフレーム）
    let pixelBuffer: CVPixelBuffer
    /// 右目の絵（空間ビデオの右の層）
    var rightEye: CVPixelBuffer?
    /// 表示の時刻（秒）
    let time: Double
    let duration: Double
    let serial: Int
}

final class VideoOutput: @unchecked Sendable {
    let synchronizer = AVSampleBufferRenderSynchronizer()
    private var rendererValue = AVSampleBufferVideoRenderer()
    /// 最後に作った形式（2D なら映像の形式、3D なら左右の目の組の形式）
    private var format: CMFormatDescription?
    private let lock = NSLock()
    private var currentRate: Float = 0
    private var stereoValue = StereoPacking.mono
    /// 左右・上下に並べたフレームを切り分ける（デコードのスレッドだけが使う）
    private let splitter = StereoSplitter()

    init() {
        synchronizer.addRenderer(rendererValue)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }

    /// 表示の時計の時刻（秒）
    var time: Double {
        let now = synchronizer.currentTime()
        return now.isValid ? now.seconds : 0
    }

    var rate: Float {
        lock.lock()
        defer { lock.unlock() }
        return currentRate
    }

    /// 時計を time に合わせ、rate で進める（0 なら止める）
    func setRate(_ rate: Float, time: Double) {
        lock.lock()
        currentRate = rate
        lock.unlock()
        synchronizer.setRate(rate, time: CMTime(seconds: time, preferredTimescale: 90_000))
    }

    /// 時刻はそのままで、進む速さだけ変える（音とのずれを少しずつ詰める）
    func adjustRate(_ rate: Float) {
        lock.lock()
        currentRate = rate
        lock.unlock()
        synchronizer.rate = rate
    }

    /// 今の renderer。3D と 2D を切り替えると作り直すので、RealityKit の VideoMaterial はこれに付け替える
    var renderer: AVSampleBufferVideoRenderer {
        lock.withLock { rendererValue }
    }

    var isReady: Bool {
        renderer.isReadyForMoreMediaData
    }

    /// 渡すフレームの左右の目の並べ方。
    /// 3D と 2D を切り替えるときは renderer を作り直す（新しい renderer は、VideoMaterial に付けられて映す先ができるまでコマを受け取らない）
    var stereo: StereoPacking {
        get { lock.withLock { stereoValue } }
        set {
            let replaced: AVSampleBufferVideoRenderer? = lock.withLock {
                guard stereoValue != newValue else {
                    return nil
                }
                let wasStereo = stereoValue != .mono
                stereoValue = newValue
                // 次のフレームで、形式を作り直す
                format = nil
                guard wasStereo != (newValue != .mono) else {
                    return nil
                }
                let old = rendererValue
                rendererValue = AVSampleBufferVideoRenderer()
                return old
            }
            if let replaced {
                synchronizer.removeRenderer(replaced, at: synchronizer.currentTime(), completionHandler: nil)
                replaced.flush()
                synchronizer.addRenderer(renderer)
            }
        }
    }

    /// フレームを渡す。displayImmediately なら時刻を待たずに表示する（止まっているときのシーク）
    func enqueue(_ frame: DecodedVideoFrame, displayImmediately: Bool = false) {
        let (target, stereo) = lock.withLock { (rendererValue, stereoValue) }
        // renderer を作り直した直後は、スクリーンにつながる（VideoMaterial が映す先を足す）まで渡さない。
        // 映す先が無いうちに渡すと、そのあと映す先を足せなくなる
        guard target.isReadyForMoreMediaData else {
            return
        }
        let timing = CMSampleTimingInfo(
            duration: CMTime(seconds: max(frame.duration, 0.001), preferredTimescale: 90_000),
            presentationTimeStamp: CMTime(seconds: frame.time, preferredTimescale: 90_000),
            decodeTimeStamp: .invalid
        )
        let sample: CMSampleBuffer? = if stereo != .mono, let eyes = eyes(of: frame, stereo: stereo) {
            stereoSample(eyes, timing: timing)
        } else {
            monoSample(frame.pixelBuffer, timing: timing)
        }
        guard let sample else {
            return
        }
        if displayImmediately, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        target.enqueue(sample)
    }

    /// 左目・右目の絵。空間ビデオは組にした 2 枚、左右・上下に並べたフレームは切り分けた 2 枚
    private func eyes(of frame: DecodedVideoFrame, stereo: StereoPacking) -> (left: CVPixelBuffer, right: CVPixelBuffer)? {
        if let right = frame.rightEye {
            return (frame.pixelBuffer, right)
        }
        return splitter.split(frame.pixelBuffer, packing: stereo)
    }

    private func monoSample(_ buffer: CVPixelBuffer, timing: CMSampleTimingInfo) -> CMSampleBuffer? {
        let cached = lock.withLock { self.format }
        let format: CMVideoFormatDescription
        if let cached, CMFormatDescriptionGetMediaType(cached) == kCMMediaType_Video,
           CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: buffer) {
            // 同じ形式のまま
            format = cached
        } else {
            var created: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &created)
            guard let created else {
                return nil
            }
            lock.withLock { self.format = created }
            format = created
        }
        var timing = timing
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: buffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        return sample
    }

    /// 左目・右目の絵に印を付けて、1 つのサンプルにまとめる（左目が層 0、右目が層 1）
    private func stereoSample(_ eyes: (left: CVPixelBuffer, right: CVPixelBuffer), timing: CMSampleTimingInfo) -> CMSampleBuffer {
        let tagged = [
            CMTaggedBuffer(tags: [.mediaType(.video), .stereoView(.leftEye), .videoLayerID(0)], pixelBuffer: eyes.left),
            CMTaggedBuffer(tags: [.mediaType(.video), .stereoView(.rightEye), .videoLayerID(1)], pixelBuffer: eyes.right)
        ]
        let cached = lock.withLock { self.format }
        let format: CMTaggedBufferGroupFormatDescription
        if let cached, CMFormatDescriptionGetMediaType(cached) == kCMMediaType_TaggedBufferGroup,
           cached.matchesTaggedBufferGroup(tagged) {
            format = cached
        } else {
            format = CMTaggedBufferGroupFormatDescription(taggedBuffers: tagged)
            lock.withLock { self.format = format }
        }
        return CMSampleBuffer(
            taggedBuffers: tagged,
            presentationTimeStamp: timing.presentationTimeStamp,
            duration: timing.duration,
            formatDescription: format
        )
    }

    /// 渡したフレームを捨てる（シークのとき）。removingImage なら、表示中の画も消す
    func flush(removingImage: Bool = false) {
        if removingImage {
            renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        } else {
            renderer.flush()
        }
    }
}
