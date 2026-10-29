//
//  VideoOutput.swift
//  TheaterMedia
//
//  映像の出口。デコードしたフレームを AVSampleBufferVideoRenderer に時刻付きで渡す。
//  RealityKit の VideoMaterial(videoRenderer:) がこの renderer をスクリーンに貼る。表示の時刻は AVSampleBufferRenderSynchronizer の
//  時計で決まり（フレームの間隔・HDR の表示はシステムが受け持つ）、音の時計に合わせてこの時計を動かす（MediaClock）。
//  3D の映像は、左右に並べたフレーム（左が左目）にして、形式に立体の指定（左右に並べてあること）を付けて渡す。VideoMaterial が
//  左右の目に分けて映す（実機で立体に見えた）。上下に並べた指定は実機で立体に映らなかったので、上下・空間ビデオは左右に並べ替える。
//  3D と 2D を切り替えるときは renderer を作り直し、VideoMaterial を付け替える（3D のあとに 2D の映像を渡すと、立体のまま崩れて映った）
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
    /// 最後に作った形式（3D なら立体の指定を付けたもの）
    private var format: CMVideoFormatDescription?
    private let lock = NSLock()
    private var currentRate: Float = 0
    private var stereoValue = StereoPacking.mono
    /// 上下に並べたフレーム・空間ビデオの左右の層を、左右に並べ替える（デコードのスレッドだけが使う）
    private let composer = SideBySideComposer()

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
        let sample: CMSampleBuffer? = if stereo != .mono, let packed = sideBySide(frame, stereo: stereo) {
            makeSample(packed, timing: timing, stereo: true)
        } else {
            makeSample(frame.pixelBuffer, timing: timing, stereo: false)
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

    /// 左右に並べたフレーム（左が左目）。上下に並べたフレームと、空間ビデオの左右の層は、左右に並べ替える
    private func sideBySide(_ frame: DecodedVideoFrame, stereo: StereoPacking) -> CVPixelBuffer? {
        if let right = frame.rightEye {
            return composer.sideBySide(left: frame.pixelBuffer, right: right)
        }
        return switch stereo {
        case .sideBySide:
            frame.pixelBuffer
        case .overUnder:
            composer.sideBySide(fromOverUnder: frame.pixelBuffer)
        case .mono, .multiview:
            nil
        }
    }

    /// 画素のバッファのサンプル。stereo なら、形式に左右に並べた立体の指定を付ける
    private func makeSample(_ buffer: CVPixelBuffer, timing: CMSampleTimingInfo, stereo: Bool) -> CMSampleBuffer? {
        let cached = lock.withLock { self.format }
        let format: CMVideoFormatDescription
        if let cached, Self.format(cached, matches: buffer, stereo: stereo) {
            // 同じ形式のまま
            format = cached
        } else {
            guard let created = Self.makeFormat(for: buffer, stereo: stereo) else {
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

    /// format を buffer にそのまま使えるか（立体の指定の有無も合わせる）
    private static func format(_ format: CMVideoFormatDescription, matches buffer: CVPixelBuffer, stereo: Bool) -> Bool {
        let hasStereo = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ViewPackingKind) != nil
        guard hasStereo == stereo else {
            return false
        }
        guard stereo else {
            return CMVideoFormatDescriptionMatchesImageBuffer(format, imageBuffer: buffer)
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        return Int(dimensions.width) == CVPixelBufferGetWidth(buffer) && Int(dimensions.height) == CVPixelBufferGetHeight(buffer)
            && CMFormatDescriptionGetMediaSubType(format) == CVPixelBufferGetPixelFormatType(buffer)
    }

    /// 画素のバッファの形式。stereo なら、左右の目の絵があること・左右に並べてあること・投影（ふつうの平面）を付ける。
    /// RealityKit の VideoMaterial は、これを見て左右の目に分けて映す
    static func makeFormat(for buffer: CVPixelBuffer, stereo: Bool) -> CMVideoFormatDescription? {
        var created: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &created)
        guard let base = created, stereo else {
            return created
        }
        var extensions = (CMFormatDescriptionGetExtensions(base) as? [CFString: Any]) ?? [:]
        extensions[kCMFormatDescriptionExtension_HasLeftStereoEyeView] = true
        extensions[kCMFormatDescriptionExtension_HasRightStereoEyeView] = true
        extensions[kCMFormatDescriptionExtension_ViewPackingKind] = kCMFormatDescriptionViewPackingKind_SideBySide
        extensions[kCMFormatDescriptionExtension_ProjectionKind] = kCMFormatDescriptionProjectionKind_Rectilinear
        var stereoFormat: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: CMFormatDescriptionGetMediaSubType(base),
            width: Int32(CVPixelBufferGetWidth(buffer)),
            height: Int32(CVPixelBufferGetHeight(buffer)),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &stereoFormat
        )
        return stereoFormat ?? base
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
