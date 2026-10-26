//
//  TestCard.swift
//  RKPreview
//
//  上映中の確認用の、試しの映像（夕焼けの山の絵）。左・中央・右の区画の平均の色（リニア）も出す。
//

import CoreGraphics
import Foundation

enum TestCard {
    static func make(width: Int, height: Int) -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            fatalError("試しの映像を描けません")
        }
        let fullWidth = CGFloat(width)
        let fullHeight = CGFloat(height)
        let sky = [
            CGColor(red: 0.10, green: 0.12, blue: 0.35, alpha: 1),
            CGColor(red: 0.85, green: 0.35, blue: 0.20, alpha: 1),
            CGColor(red: 1.0, green: 0.75, blue: 0.35, alpha: 1)
        ]
        if let gradient = CGGradient(colorsSpace: space, colors: sky as CFArray, locations: [0, 0.7, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: fullHeight), end: CGPoint(x: 0, y: fullHeight * 0.3), options: [])
        }
        context.setFillColor(CGColor(red: 1.0, green: 0.92, blue: 0.6, alpha: 1))
        context.fillEllipse(in: CGRect(x: fullWidth * 0.62, y: fullHeight * 0.32, width: fullHeight * 0.22, height: fullHeight * 0.22))
        context.setFillColor(CGColor(red: 0.12, green: 0.06, blue: 0.10, alpha: 1))
        context.beginPath()
        context.move(to: CGPoint.zero)
        let ridge: [(CGFloat, CGFloat)] = [
            (0, 0.38), (0.12, 0.48), (0.25, 0.36), (0.38, 0.52), (0.5, 0.40), (0.62, 0.44),
            (0.75, 0.33), (0.88, 0.46), (1, 0.37)
        ]
        for (x, y) in ridge {
            context.addLine(to: CGPoint(x: x * fullWidth, y: y * fullHeight))
        }
        context.addLine(to: CGPoint(x: fullWidth, y: 0))
        context.closePath()
        context.fillPath()
        guard let image = context.makeImage() else {
            fatalError("試しの映像を描けません")
        }
        return image
    }

    /// 左・中央・右の 3 区画の平均の色（リニア）
    static func zoneAverages(_ image: CGImage) -> [SIMD3<Float>] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &bytes,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return [SIMD3](repeating: .zero, count: 3)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sums = [SIMD3<Float>](repeating: .zero, count: 3)
        var counts = [Float](repeating: 0, count: 3)
        for row in stride(from: 0, to: height, by: 4) {
            for column in stride(from: 0, to: width, by: 4) {
                let index = (row * width + column) * 4
                let rgb = SIMD3(Float(bytes[index]), Float(bytes[index + 1]), Float(bytes[index + 2])) / 255
                let zone = min(2, column * 3 / width)
                sums[zone] += linear(rgb)
                counts[zone] += 1
            }
        }
        return (0..<3).map { sums[$0] / max(counts[$0], 1) }
    }

    static func linear(_ srgb: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(linear(srgb.x), linear(srgb.y), linear(srgb.z))
    }

    static func linear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
