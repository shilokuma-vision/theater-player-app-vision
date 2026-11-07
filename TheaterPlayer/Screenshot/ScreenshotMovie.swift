//
//  ScreenshotMovie.swift
//  TheaterPlayer
//
//  撮影モードでスクリーンに映す動画。外部の素材を使わないよう、夕焼けの山並みの絵をその場で描き、H.264 の動画にする。
//  一時停止して決まった位置（position）を映すので、絵は 1 枚で、コマは頭とその位置の前後と終わりにだけ置く
//  （長さは長編の映画ほどにして、操作パネルの時刻を映画らしくする）。
//  Debug と撮影のビルド（SCREENSHOT_DEMO）にだけ入る。
//

#if DEBUG || SCREENSHOT_DEMO
import AVFoundation
import CoreGraphics
import Foundation

enum ScreenshotMovie {
    /// 動画の長さ（秒。1:52:30）
    static let duration: Double = 6_750
    /// 一時停止して映す位置（秒。47:12）
    static let position: Double = 2_832
    /// 絵の大きさ（シネマスコープ 2.4:1）
    static let width = 1_920
    static let height = 800

    enum Failure: Error {
        case drawing
        case writing(Error?)
    }

    /// url に動画を書き出す（もうあれば書き出さない）
    static func write(to url: URL) async throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        guard let image = drawFrame() else {
            throw Failure.drawing
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 書きかけのファイルを開かないよう、別の名前で書いてから移す
        let partial = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.writing(writer.error)
        }
        writer.startSession(atSourceTime: .zero)
        for time in frameTimes {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let buffer = pixelBuffer(of: image, pool: adaptor.pixelBufferPool),
                  adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)) else {
                writer.cancelWriting()
                throw Failure.writing(writer.error)
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.writing(writer.error)
        }
        try FileManager.default.moveItem(at: partial, to: url)
    }

    private static var outputSettings: [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // コマがまばらなので、1 コマに多くのビットを使える（にじみ・縞が出ないよう高めにする）
                AVVideoAverageBitRateKey: 20_000_000,
                // どのコマからでもシークできるよう、すべてキーフレームにする
                AVVideoMaxKeyFrameIntervalKey: 1,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
    }

    /// コマを置く時刻：頭、映す位置の少し前から少しあと（シークした先で、デコーダーが位置より後ろのコマを見つけられるように）、終わり
    private static var frameTimes: [Double] {
        [0] + Array(stride(from: position - 5, through: position + 25, by: 1)) + [duration - 1]
    }

    private static func pixelBuffer(of image: CGImage, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let buffer = created else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context == nil ? nil : buffer
    }

    /// 夕焼けの山並みと湖の絵
    static func drawFrame() -> CGImage? {
        let size = CGSize(width: width, height: height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        // 上を y = 0 にする
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        MoviePainter(context: context, size: size, space: space).paint()
        return context.makeImage()
    }
}

// MARK: - 絵を描く

/// 決まった列を出す乱数（SplitMix64）。絵が撮るたびに変わらないようにする
private struct DemoRandom {
    var state: UInt64

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / Double(1 << 53)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * next()
    }
}

/// グラデーションの色の止まり
private struct ColorStop {
    var location: Double
    var hex: Int
    var alpha: Double = 1
}

/// 山並みの 1 重
private struct MountainLayer {
    /// 地平線からの高さの下限と幅（絵の高さに対する割合）
    var base: Double
    var height: Double
    var hex: Int
    var seed: UInt64
    /// 太陽の下を谷にする（沈みかけた太陽が見えるように）
    var opensValley: Bool
}

/// 鳥（位置は絵の大きさに対する割合、翼の幅は画素）
private struct Bird {
    var x: Double
    var y: Double
    var span: CGFloat
}

/// 尾根の線（左から右）と色
private struct Ridge {
    var points: [CGPoint]
    var color: CGColor
}

/// 空・太陽・雲・4 重の山・湖の映り込み・手前の丘の木・鳥を、決まった乱数で描く
private struct MoviePainter {
    let context: CGContext
    let size: CGSize
    let space: CGColorSpace

    var horizon: CGFloat { size.height * 0.6 }
    var sun: CGPoint { CGPoint(x: size.width * 0.6, y: horizon - size.height * 0.12) }

    func paint() {
        sky()
        stars()
        glow()
        sunDisc()
        clouds()
        let ridges = mountainRidges()
        for ridge in ridges {
            fill(ridge.points, down: horizon, color: ridge.color)
        }
        lake(ridges: ridges)
        foreground()
        birds()
        vignette()
    }

    // MARK: 道具

    func color(_ hex: Int, alpha: Double = 1) -> CGColor {
        let channels = [hex >> 16, hex >> 8, hex].map { CGFloat($0 & 0xFF) / 255 }
        return CGColor(colorSpace: space, components: channels + [CGFloat(alpha)]) ?? CGColor(gray: 0, alpha: 1)
    }

    private func gradient(_ stops: [ColorStop]) -> CGGradient? {
        let colors = stops.map { color($0.hex, alpha: $0.alpha) }
        return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops.map { CGFloat($0.location) })
    }

    func linear(_ stops: [ColorStop], from start: CGPoint, to end: CGPoint) {
        if let gradient = gradient(stops) {
            context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    func radial(_ stops: [ColorStop], center: CGPoint, radius: CGFloat) {
        if let gradient = gradient(stops) {
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
    }

    /// 角の丸い横長の帯
    func capsule(_ rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
    }

    func fill(_ ridge: [CGPoint], down bottom: CGFloat, color: CGColor) {
        guard let first = ridge.first, let last = ridge.last else {
            return
        }
        context.beginPath()
        context.move(to: CGPoint(x: first.x, y: bottom))
        for point in ridge {
            context.addLine(to: point)
        }
        context.addLine(to: CGPoint(x: last.x, y: bottom))
        context.closePath()
        context.setFillColor(color)
        context.fillPath()
    }
}

// MARK: 空

private extension MoviePainter {
    func sky() {
        let stops = [(0, 0x2C2A72), (0.25, 0x6A3C96), (0.5, 0xC9568A), (0.7, 0xF57E78), (0.86, 0xFFB264), (1, 0xFFE2A0)]
        linear(stops.map { ColorStop(location: $0.0, hex: $0.1) }, from: .zero, to: CGPoint(x: 0, y: horizon))
    }

    func stars() {
        var random = DemoRandom(state: 7)
        let band = horizon * 0.35
        for _ in 0..<90 {
            let point = CGPoint(x: random.next() * size.width, y: pow(random.next(), 1.6) * band)
            let radius = random.next(in: 0.6...1.8)
            context.setFillColor(color(0xFFF4E8, alpha: random.next(in: 0.25...0.9) * (1 - point.y / band)))
            context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    func glow() {
        radial(
            [
                ColorStop(location: 0, hex: 0xFFE09A, alpha: 0.9),
                ColorStop(location: 0.2, hex: 0xFFA552, alpha: 0.55),
                ColorStop(location: 0.55, hex: 0xF0607E, alpha: 0.2),
                ColorStop(location: 1, hex: 0xF0607E, alpha: 0)
            ],
            center: sun,
            radius: size.height * 0.75
        )
    }

    func sunDisc() {
        let radius = size.height * 0.08
        radial(
            [ColorStop(location: 0, hex: 0xFFFBEA), ColorStop(location: 0.7, hex: 0xFFE9A8), ColorStop(location: 1, hex: 0xFFC56E)],
            center: sun,
            radius: radius
        )
        // 縁をくっきりさせず、少しだけにじませる
        radial(
            [ColorStop(location: 0.9, hex: 0xFFE2A0, alpha: 0.6), ColorStop(location: 1, hex: 0xFFE2A0, alpha: 0)],
            center: sun,
            radius: radius * 1.25
        )
    }

    /// 夕日に照らされた細い雲。両端を空に溶かす
    func clouds() {
        var random = DemoRandom(state: 21)
        for _ in 0..<12 {
            let rect = CGRect(
                x: size.width * random.next(in: -0.1...0.95),
                y: horizon * random.next(in: 0.3...0.8),
                width: size.width * random.next(in: 0.1...0.32),
                height: size.height * random.next(in: 0.006...0.02)
            )
            // 太陽に近い雲は下から金色に照らされ、遠い雲は紫に沈む
            let near = max(0, 1 - abs(rect.midX - sun.x) / (size.width * 0.4))
            let tint = near > 0.35 ? 0xFFC080 : 0xC86A9A
            let alpha = 0.3 + near * 0.45
            context.saveGState()
            context.addPath(capsule(rect))
            context.clip()
            linear(
                [
                    ColorStop(location: 0, hex: tint, alpha: 0),
                    ColorStop(location: 0.3, hex: tint, alpha: alpha),
                    ColorStop(location: 0.7, hex: tint, alpha: alpha),
                    ColorStop(location: 1, hex: tint, alpha: 0)
                ],
                from: CGPoint(x: rect.minX, y: rect.midY),
                to: CGPoint(x: rect.maxX, y: rect.midY)
            )
            context.restoreGState()
        }
    }
}

// MARK: 山と湖

private extension MoviePainter {
    /// 奥から手前へ 4 重の山並み。奥ほど高く、空の色に溶ける
    func mountainRidges() -> [Ridge] {
        let layers = [
            MountainLayer(base: 0.10, height: 0.20, hex: 0xC86A8C, seed: 3, opensValley: true),
            MountainLayer(base: 0.06, height: 0.15, hex: 0x924878, seed: 5, opensValley: true),
            MountainLayer(base: 0.03, height: 0.09, hex: 0x5E2C5E, seed: 11, opensValley: false),
            MountainLayer(base: 0.005, height: 0.04, hex: 0x341840, seed: 13, opensValley: false)
        ]
        return layers.map { Ridge(points: ridge(of: $0), color: color($0.hex)) }
    }

    /// 重ねた正弦波で尾根を作る
    private func ridge(of layer: MountainLayer) -> [CGPoint] {
        var random = DemoRandom(state: layer.seed)
        let waves = (0..<5).map { octave in
            (frequency: Double(octave + 1) * random.next(in: 1.4...2.6), phase: random.next(in: 0...(2 * .pi)))
        }
        let amplitudes = (0..<5).map { pow(0.55, Double($0)) }
        let total = amplitudes.reduce(0, +)
        return stride(from: 0, through: Double(size.width), by: 4).map { x -> CGPoint in
            let progress = x / Double(size.width)
            let value = zip(waves, amplitudes).reduce(0) { $0 + $1.1 * sin(progress * $1.0.frequency * .pi * 2 + $1.0.phase) }
            let normalized = (value / total + 1) / 2
            let valley = layer.opensValley ? 1 - 0.65 * exp(-pow((x - Double(sun.x)) / (Double(size.width) * 0.1), 2)) : 1
            let rise = (layer.base + layer.height * pow(normalized, 1.4)) * valley * Double(size.height)
            return CGPoint(x: x, y: Double(horizon) - rise)
        }
    }

    /// 地平線から下は湖。空と山を上下に返して映し、下ほど暗くする。太陽の光の帯をきらめかせる
    func lake(ridges: [Ridge]) {
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon))
        context.translateBy(x: 0, y: horizon * 2)
        context.scaleBy(x: 1, y: -1)
        sky()
        glow()
        for ridge in ridges {
            fill(ridge.points, down: horizon, color: ridge.color)
        }
        context.restoreGState()
        linear(
            [
                ColorStop(location: 0, hex: 0x1A0B26, alpha: 0.2),
                ColorStop(location: 0.4, hex: 0x14081F, alpha: 0.45),
                ColorStop(location: 1, hex: 0x0A0510, alpha: 0.75)
            ],
            from: CGPoint(x: 0, y: horizon),
            to: CGPoint(x: 0, y: size.height)
        )
        var random = DemoRandom(state: 31)
        var y = horizon + 3
        while y < size.height {
            let depth = (y - horizon) / (size.height - horizon)
            let width = size.height * (0.16 + depth * 0.5) * random.next(in: 0.4...1.2)
            let height = 1.5 + depth * 4
            let x = sun.x + size.height * 0.03 * random.next(in: -1...1) - width / 2
            context.setFillColor(color(0xFFD890, alpha: (1 - depth) * random.next(in: 0.35...0.8)))
            context.addPath(capsule(CGRect(x: x, y: y, width: width, height: height)))
            context.fillPath()
            y += height + 2 + depth * 6
        }
    }
}

// MARK: 手前

private extension MoviePainter {
    /// 左右の手前の丘と、そこに立つ木（影絵）
    func foreground() {
        let dark = color(0x0B0612)
        let leftEnd = Double(size.width) * 0.36
        let left = stride(from: 0, through: leftEnd, by: 4).map { x -> CGPoint in
            let progress = x / leftEnd
            return CGPoint(x: x, y: Double(size.height) * (0.66 + 0.34 * pow(progress, 1.8)) - 6 * sin(progress * 9))
        }
        fill(left, down: size.height, color: dark)
        let rightStart = Double(size.width) * 0.78
        let right = stride(from: rightStart, through: Double(size.width), by: 4).map { x -> CGPoint in
            let progress = (Double(size.width) - x) / (Double(size.width) - rightStart)
            return CGPoint(x: x, y: Double(size.height) * (0.74 + 0.26 * pow(progress, 1.6)) - 5 * sin(progress * 7))
        }
        fill(right, down: size.height, color: dark)
        var random = DemoRandom(state: 41)
        for (index, point) in left.enumerated() where index.isMultiple(of: 9) && point.y < size.height * 0.9 {
            tree(at: point, height: size.height * random.next(in: 0.12...0.24), color: dark)
        }
        for (index, point) in right.enumerated() where index.isMultiple(of: 11) && point.y < size.height * 0.92 {
            tree(at: point, height: size.height * random.next(in: 0.08...0.16), color: dark)
        }
    }

    /// 針葉樹：重ねた三角と幹
    private func tree(at base: CGPoint, height: CGFloat, color: CGColor) {
        context.setFillColor(color)
        let width = height * 0.42
        context.fill(CGRect(x: base.x - width * 0.05, y: base.y - height * 0.2, width: width * 0.1, height: height * 0.25))
        for tier in 0..<4 {
            let top = base.y - height + CGFloat(tier) * height * 0.2
            let bottom = top + height * 0.38
            let half = width * (0.28 + CGFloat(tier) * 0.08)
            context.beginPath()
            context.move(to: CGPoint(x: base.x, y: top))
            context.addLine(to: CGPoint(x: base.x + half, y: bottom))
            context.addLine(to: CGPoint(x: base.x - half, y: bottom))
            context.closePath()
            context.fillPath()
        }
    }

    /// 太陽の左を渡る鳥
    func birds() {
        context.setStrokeColor(color(0x1A0C22, alpha: 0.85))
        context.setLineWidth(2.2)
        context.setLineCap(.round)
        let flock = [
            Bird(x: 0.42, y: 0.22, span: 16), Bird(x: 0.45, y: 0.25, span: 12), Bird(x: 0.4, y: 0.27, span: 11),
            Bird(x: 0.47, y: 0.2, span: 9), Bird(x: 0.44, y: 0.3, span: 8)
        ]
        for bird in flock {
            let center = CGPoint(x: size.width * bird.x, y: size.height * bird.y)
            let span = bird.span
            context.beginPath()
            context.move(to: CGPoint(x: center.x - span, y: center.y - span * 0.35))
            context.addQuadCurve(to: center, control: CGPoint(x: center.x - span * 0.5, y: center.y - span * 0.5))
            context.addQuadCurve(
                to: CGPoint(x: center.x + span, y: center.y - span * 0.35),
                control: CGPoint(x: center.x + span * 0.5, y: center.y - span * 0.5)
            )
            context.strokePath()
        }
    }

    func vignette() {
        radial(
            [ColorStop(location: 0.55, hex: 0, alpha: 0), ColorStop(location: 1, hex: 0, alpha: 0.5)],
            center: CGPoint(x: size.width / 2, y: size.height / 2),
            radius: hypot(size.width, size.height) / 2
        )
    }
}
#endif
