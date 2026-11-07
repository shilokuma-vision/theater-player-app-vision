//
//  Picture.swift
//  ReviewSample
//
//  サンプルの動画の絵（1920 × 1080）。Core Graphics で描く（文字・カラーバー・スピーカーの配置図・オーロラのような帯・エンドロール）。
//  座標は左下が原点。
//

import CoreGraphics
import CoreText
import Foundation

struct Picture {
    static let width = 1_920
    static let height = 1_080

    private let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let size = CGSize(width: Picture.width, height: Picture.height)

    func draw(in context: CGContext, time: Double) {
        let (part, local) = Part.at(time)
        switch part {
        case .title:
            drawTitle(in: context)
        case .countdown:
            drawCountdown(in: context, local: local)
        case .bars:
            drawBars(in: context)
        case .speakers:
            let (speaker, isOn) = Speaker.check(at: local)
            let number = (Speaker.checkOrder.firstIndex(of: speaker) ?? 0) + 1
            drawRoom(in: context, gains: [speaker: isOn ? 1 : 0.35], dotAngle: nil)
            caption(speaker.name, detail: "Speaker check \u{00B7} \(number) of \(Speaker.checkOrder.count)", in: context)
        case .around:
            let angle = Speaker.aroundAngle(at: local)
            drawRoom(in: context, gains: Speaker.panGains(angle: angle), dotAngle: angle)
            caption("Around the Theater", detail: "The sound circles the room twice", in: context)
        case .music:
            drawAurora(in: context, time: time)
            let alpha = Sound.fade(local, length: 10, edge: 1.5)
            let label = "Ambient Music \u{00B7} generated in code"
            text(label, size: 30, color: color(1, 1, 1, alpha * 0.8), at: CGPoint(x: 360, y: 80), in: context)
        case .credits:
            drawCredits(in: context, local: local)
        }
        // 区切りの始まりと終わりは、黒から出て黒へ戻す（カウントダウンとカラーバー、スピーカーの確認の境目は切り替えるだけ）
        let edge = part == .title || part == .music || part == .credits ? 1.0 : 0.25
        let black = 1 - Sound.fade(local, length: part.length, edge: edge)
        if black > 0 {
            context.setFillColor(color(0, 0, 0, black))
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - 区切りごとの絵

    private func drawTitle(in context: CGContext) {
        fillGradient(top: color(0.08, 0.06, 0.16), bottom: color(0.01, 0.02, 0.05), in: context)
        text("Theater Player", size: 132, bold: true, color: color(1, 1, 1), at: CGPoint(x: 960, y: 610), in: context)
        text("Sample Video for App Review", size: 56, color: color(0.85, 0.85, 0.9), at: CGPoint(x: 960, y: 480), in: context)
        let note = "Test patterns, sound, and music generated in code \u{00B7} No third-party content"
        text(note, size: 30, color: color(0.6, 0.6, 0.7), at: CGPoint(x: 960, y: 380), in: context)
    }

    /// 映画のリーダーのようなカウントダウン（10 から 1）
    private func drawCountdown(in context: CGContext, local: Double) {
        context.setFillColor(color(0.16, 0.16, 0.17))
        context.fill(CGRect(origin: .zero, size: size))
        let center = CGPoint(x: 960, y: 540)
        let fraction = local - floor(local)
        context.setFillColor(color(1, 1, 1, 0.18))
        context.move(to: center)
        context.addArc(center: center, radius: 400, startAngle: .pi / 2, endAngle: .pi / 2 - fraction * 2 * .pi, clockwise: true)
        context.closePath()
        context.fillPath()
        context.setStrokeColor(color(1, 1, 1, 0.75))
        context.setLineWidth(6)
        for radius in [400.0, 330] {
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        context.setLineWidth(3)
        context.strokeLineSegments(between: [
            CGPoint(x: 0, y: 540), CGPoint(x: 1_920, y: 540), CGPoint(x: 960, y: 0), CGPoint(x: 960, y: 1_080)
        ])
        text("\(10 - Int(local))", size: 380, bold: true, color: color(1, 1, 1), at: center, in: context)
    }

    /// カラーバー（75 %）とグレーの階調
    private func drawBars(in context: CGContext) {
        let top: [CGColor] = [
            color(0.75, 0.75, 0.75), color(0.75, 0.75, 0), color(0, 0.75, 0.75), color(0, 0.75, 0),
            color(0.75, 0, 0.75), color(0.75, 0, 0), color(0, 0, 0.75)
        ]
        let middle: [CGColor] = [
            color(0, 0, 0.75), color(0.07, 0.07, 0.07), color(0.75, 0, 0.75), color(0.07, 0.07, 0.07),
            color(0, 0.75, 0.75), color(0.07, 0.07, 0.07), color(0.75, 0.75, 0.75)
        ]
        let barWidth = CGFloat(Picture.width) / CGFloat(top.count)
        for (index, (upper, lower)) in zip(top, middle).enumerated() {
            let left = CGFloat(index) * barWidth
            context.setFillColor(upper)
            context.fill(CGRect(x: left, y: 360, width: barWidth + 1, height: 720))
            context.setFillColor(lower)
            context.fill(CGRect(x: left, y: 270, width: barWidth + 1, height: 90))
        }
        context.setFillColor(color(0.07, 0.07, 0.07))
        context.fill(CGRect(x: 0, y: 0, width: 1_920, height: 270))
        for step in 0..<11 {
            let level = Double(step) / 10
            context.setFillColor(color(level, level, level))
            context.fill(CGRect(x: 60 + CGFloat(step) * 90, y: 60, width: 90, height: 150))
        }
        text("1 kHz  \u{2212}20 dBFS  (L + R)", size: 44, color: color(1, 1, 1), at: CGPoint(x: 1_480, y: 135), in: context)
    }

    /// 映画館を上から見たスピーカーの配置図。gains の大きいスピーカーほど明るく塗る
    private func drawRoom(in context: CGContext, gains: [Speaker: Double], dotAngle: Double?) {
        fillGradient(top: color(0.07, 0.07, 0.1), bottom: color(0.02, 0.02, 0.03), in: context)
        let center = CGPoint(x: 960, y: 600)
        context.setFillColor(color(0.85, 0.85, 0.9))
        context.fill(CGRect(x: 560, y: 990, width: 800, height: 12))
        context.setStrokeColor(color(1, 1, 1, 0.15))
        context.setLineWidth(3)
        context.strokeEllipse(in: CGRect(x: center.x - 560, y: center.y - 330, width: 1_120, height: 660))
        context.setFillColor(color(0.55, 0.6, 0.7))
        context.fillEllipse(in: CGRect(x: center.x - 34, y: center.y - 34, width: 68, height: 68))
        for speaker in Speaker.allCases {
            let position = speaker.angle.map { point(center: center, angle: $0, scale: 1) } ?? CGPoint(x: 1_120, y: 930)
            let gain = gains[speaker] ?? 0
            context.setFillColor(color(0.25 + 0.75 * gain, 0.25 + 0.55 * gain, 0.28 - 0.08 * gain))
            let box = CGRect(x: position.x - 40, y: position.y - 40, width: 80, height: 80)
            context.addPath(CGPath(roundedRect: box, cornerWidth: 14, cornerHeight: 14, transform: nil))
            context.fillPath()
            let label = gain > 0.5 ? color(0.1, 0.08, 0.02) : color(1, 1, 1, 0.85)
            text(speaker.shortName, size: speaker == .lfe ? 24 : 32, bold: true, color: label, at: position, in: context)
        }
        if let dotAngle {
            let dot = point(center: center, angle: dotAngle, scale: 0.8)
            context.setFillColor(color(1, 0.85, 0.35, 0.3))
            context.fillEllipse(in: CGRect(x: dot.x - 44, y: dot.y - 44, width: 88, height: 88))
            context.setFillColor(color(1, 0.9, 0.5))
            context.fillEllipse(in: CGRect(x: dot.x - 20, y: dot.y - 20, width: 40, height: 40))
        }
    }

    /// 音楽のあいだの、ゆっくり動く光の帯と星
    private func drawAurora(in context: CGContext, time: Double) {
        fillGradient(top: color(0.01, 0.02, 0.06), bottom: color(0.03, 0.05, 0.12), in: context)
        for star in 0..<160 {
            let seed = Double(star) * 12.9898
            let x = (sin(seed) * 43_758.545).truncatingRemainder(dividingBy: 1).magnitude * 1_920
            let y = (sin(seed * 1.7) * 24_634.634).truncatingRemainder(dividingBy: 1).magnitude * 1_080
            let twinkle = 0.45 + 0.35 * sin(time * (0.6 + Double(star % 7) * 0.13) + seed)
            context.setFillColor(color(1, 1, 1, twinkle))
            context.fillEllipse(in: CGRect(x: x, y: y, width: 3, height: 3))
        }
        context.setBlendMode(.plusLighter)
        for band in 0..<4 {
            let phase = Double(band) * 1.9
            let hue = (0.42 + Double(band) * 0.08 + 0.06 * sin(time / 23 + phase)).truncatingRemainder(dividingBy: 1)
            let base = 380 + Double(band) * 90 + 40 * sin(time / 17 + phase)
            for layer in 0..<6 {
                let path = CGMutablePath()
                for column in 0...96 {
                    let x = Double(column) * 20
                    let wave = 70 * sin(x / 330 + time * 0.21 + phase) + 30 * sin(x / 140 - time * 0.33 + phase * 2)
                    let point = CGPoint(x: x, y: base + wave + Double(layer) * 14)
                    if column == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                context.addPath(path)
                context.setStrokeColor(hsb(hue, 0.7, 0.9, 0.05 + 0.03 * Double(6 - layer)))
                context.setLineWidth(28 - CGFloat(layer) * 3)
                context.strokePath()
            }
        }
        context.setBlendMode(.normal)
    }

    /// 黒地に白い文字が下から上へ流れるエンドロール
    private func drawCredits(in context: CGContext, local: Double) {
        context.setFillColor(color(0, 0, 0))
        context.fill(CGRect(origin: .zero, size: size))
        let lines: [(String, CGFloat)] = [
            ("Theater Player", 72), ("Sample Video for App Review", 40), ("", 40),
            ("Picture", 28), ("Test patterns and animation drawn with Core Graphics", 38), ("", 40),
            ("Sound", 28), ("Tones, pink noise, and music synthesized in code", 38), ("5.1 channels: L, R, C, LFE, Ls, Rs", 38), ("", 40),
            ("Made with", 28), ("Tools/ReviewSample in the Theater Player repository", 38), ("", 40),
            ("No third-party content is used in this video.", 38), ("", 80), ("Thank you for watching", 52)
        ]
        let spacing: CGFloat = 1.9
        let total = lines.reduce(0) { $0 + $1.1 * spacing }
        let scroll = (CGFloat(Picture.height) + total) * CGFloat(local / (Part.credits.length - 8))
        var y = scroll - 40
        for (line, fontSize) in lines {
            if !line.isEmpty, y > -100, y < 1_180 {
                let gray: CGFloat = fontSize == 28 ? 0.6 : 0.95
                text(line, size: fontSize, bold: fontSize > 50, color: color(gray, gray, gray), at: CGPoint(x: 960, y: y), in: context)
            }
            y -= fontSize * spacing
        }
    }

    // MARK: - 部品

    private func caption(_ title: String, detail: String, in context: CGContext) {
        text(title, size: 72, bold: true, color: color(1, 1, 1), at: CGPoint(x: 960, y: 150), in: context)
        text(detail, size: 32, color: color(0.7, 0.7, 0.75), at: CGPoint(x: 960, y: 70), in: context)
    }

    /// 配置図の中心から、正面を 0 度として右回りの角度にある点
    private func point(center: CGPoint, angle: Double, scale: Double) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(x: center.x + sin(radians) * 560 * scale, y: center.y + cos(radians) * 330 * scale)
    }

    private func fillGradient(top: CGColor, bottom: CGColor, in context: CGContext) {
        guard let gradient = CGGradient(colorsSpace: space, colors: [bottom, top] as CFArray, locations: [0, 1]) else {
            return
        }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: Picture.height), options: [])
    }

    /// 中心を指定して 1 行の文字を描く
    private func text(_ string: String, size: CGFloat, bold: Bool = false, color: CGColor, at center: CGPoint, in context: CGContext) {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
        CTLineDraw(line, context)
    }

    private func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
        CGColor(colorSpace: space, components: [red, green, blue, alpha]) ?? CGColor(gray: 0, alpha: 1)
    }

    private func hsb(_ hue: Double, _ saturation: Double, _ brightness: Double, _ alpha: Double) -> CGColor {
        let sector = hue * 6
        let chroma = brightness * saturation
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let base = brightness - chroma
        let rgb: [Double] = switch Int(sector) % 6 {
        case 0: [chroma, second, 0]
        case 1: [second, chroma, 0]
        case 2: [0, chroma, second]
        case 3: [0, second, chroma]
        case 4: [second, 0, chroma]
        default: [chroma, 0, second]
        }
        return color(rgb[0] + base, rgb[1] + base, rgb[2] + base, alpha)
    }
}
