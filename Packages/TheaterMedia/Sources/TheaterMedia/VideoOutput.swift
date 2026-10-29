//
//  VideoOutput.swift
//  TheaterMedia
//
//  映像の出口。デコードしたフレームを AVSampleBufferVideoRenderer に時刻付きで渡す。
//  RealityKit の VideoMaterial(videoRenderer:) がこの renderer をスクリーンに貼る。表示の時刻は AVSampleBufferRenderSynchronizer の
//  時計で決まり（フレームの間隔・HDR の表示はシステムが受け持つ）、音の時計に合わせてこの時計を動かす（MediaClock）。
//

@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// デコードしたフレーム
struct DecodedVideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    /// 表示の時刻（秒）
    let time: Double
    let duration: Double
    let serial: Int
}

final class VideoOutput: @unchecked Sendable {
    let renderer = AVSampleBufferVideoRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()
    private var format: CMVideoFormatDescription?
    private let lock = NSLock()
    private var currentRate: Float = 0
    private var stereoValue = StereoPacking.mono

    init() {
        synchronizer.addRenderer(renderer)
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

    var isReady: Bool {
        renderer.isReadyForMoreMediaData
    }

    /// 渡すフレームの左右の目の並べ方（左右・上下なら、映像の形式に立体の指定を付ける）
    var stereo: StereoPacking {
        get { lock.withLock { stereoValue } }
        set {
            lock.withLock {
                if stereoValue != newValue {
                    stereoValue = newValue
                    // 次のフレームで、立体の指定を付けた形式を作り直す
                    format = nil
                }
            }
        }
    }

    /// フレームを渡す。displayImmediately なら時刻を待たずに表示する（止まっているときのシーク）
    func enqueue(_ frame: DecodedVideoFrame, displayImmediately: Bool = false) {
        let (cached, stereo) = lock.withLock { (self.format, stereoValue) }
        let format: CMVideoFormatDescription
        if let cached, CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: frame.pixelBuffer) {
            // 同じ形式のまま
            format = cached
        } else {
            guard let created = Self.makeFormat(for: frame.pixelBuffer, stereo: stereo) else {
                return
            }
            lock.withLock { self.format = created }
            format = created
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: max(frame.duration, 0.001), preferredTimescale: 90_000),
            presentationTimeStamp: CMTime(seconds: frame.time, preferredTimescale: 90_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: frame.pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
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
        renderer.enqueue(sample)
    }

    /// 画素のバッファの形式。左右・上下に並べた立体なら、左右の目の絵があること・並べ方・投影（ふつうの平面）を付ける。
    /// RealityKit の VideoMaterial は、これを見て左右の目に分けて映す
    static func makeFormat(for buffer: CVPixelBuffer, stereo: StereoPacking) -> CMVideoFormatDescription? {
        var created: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &created)
        guard let base = created else {
            return nil
        }
        let packing: CFString
        switch stereo.output {
        case .sideBySide:
            packing = kCMFormatDescriptionViewPackingKind_SideBySide
        case .overUnder:
            packing = kCMFormatDescriptionViewPackingKind_OverUnder
        case .mono, .multiview:
            return base
        }
        var extensions = (CMFormatDescriptionGetExtensions(base) as? [CFString: Any]) ?? [:]
        extensions[kCMFormatDescriptionExtension_HasLeftStereoEyeView] = true
        extensions[kCMFormatDescriptionExtension_HasRightStereoEyeView] = true
        extensions[kCMFormatDescriptionExtension_ViewPackingKind] = packing
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
