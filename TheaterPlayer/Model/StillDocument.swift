//
//  StillDocument.swift
//  TheaterPlayer
//
//  静止画のファイル（画像・PDF）。映画館のスクリーンに貼る画像を作る。
//  - 画像：ImageIO で読めるもの（PNG・JPEG・HEIC・GIF・WebP・TIFF など）。動く GIF などは最初のコマ
//  - PDF：ページごとに画像にする（白の地に描く。/Rotate の向きも直す）
//  スクリーンは幅 21 m あるが、Vision Pro の負荷（画像の大きさ・メモリ）を考えて、長い辺を maxPixels（既定 4096）までに縮める。
//  重い処理（読み込み・縮小・PDF の描画）は MainActor の外で行う。
//

import CoreGraphics
import Foundation
import ImageIO
import TheaterMedia
import UniformTypeIdentifiers

nonisolated struct StillDocument: Sendable {
    enum Kind: String, Codable, Sendable {
        case image, pdf
    }

    let url: URL
    let kind: Kind
    /// ページの数（画像は 1）
    let pageCount: Int

    /// スクリーンに貼る画像の長い辺の画素の数の上限
    static let maxPixels = 4096

    /// url が画像・PDF なら、その種類（動画・音楽・そのほかなら nil）
    static func kind(of url: URL) -> Kind? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
        guard let type else {
            return nil
        }
        if type.conforms(to: .pdf) {
            return .pdf
        }
        // 動画・音楽のほうを先に見る（画像の型も持つ形式があっても、再生できる物は再生する）
        if type.conforms(to: .audiovisualContent) {
            return nil
        }
        return type.conforms(to: .image) ? .image : nil
    }

    /// 開いて、ページの数を数える
    static func open(_ url: URL) throws -> StillDocument {
        switch kind(of: url) {
        case .pdf:
            guard let document = CGPDFDocument(url as CFURL) else {
                throw StillError(String(localized: "Can’t open this PDF."))
            }
            guard document.isUnlocked else {
                throw StillError(String(localized: "Can’t open a password-protected PDF."))
            }
            guard document.numberOfPages > 0 else {
                throw StillError(String(localized: "This PDF has no pages."))
            }
            return StillDocument(url: url, kind: .pdf, pageCount: document.numberOfPages)
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
                throw StillError(String(localized: "Can’t open this picture."))
            }
            return StillDocument(url: url, kind: .image, pageCount: 1)
        case nil:
            throw StillError(String(localized: "This isn’t a picture or a PDF."))
        }
    }

    /// page 番目（0 から）を、スクリーンに貼る画像にする
    func render(page: Int, maxPixels: Int = Self.maxPixels) throws -> StillPicture {
        let image = switch kind {
        case .image:
            try Self.renderImage(url, maxPixels: maxPixels)
        case .pdf:
            try Self.renderPDF(url, page: page, maxPixels: maxPixels)
        }
        return StillPicture(
            url: url,
            kind: kind,
            page: page,
            pageCount: pageCount,
            image: image,
            light: StillLight.measure(image)
        )
    }

    // MARK: - 画像

    private static func renderImage(_ url: URL, maxPixels: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw StillError(String(localized: "Can’t open this picture."))
        }
        // 縮めて読む（大きな写真でもメモリを使いすぎない）。写真の向き（EXIF）も直す
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw StillError(String(localized: "Can’t open this picture."))
        }
        return image
    }

    // MARK: - PDF

    private static func renderPDF(_ url: URL, page index: Int, maxPixels: Int) throws -> CGImage {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: index + 1) else {
            throw StillError(String(localized: "Can’t open this page of the PDF."))
        }
        let box = page.getBoxRect(.cropBox)
        let angle = ((Int(page.rotationAngle) % 360) + 360) % 360
        let size = angle.isMultiple(of: 180) ? box.size : CGSize(width: box.height, height: box.width)
        guard size.width > 0, size.height > 0 else {
            throw StillError(String(localized: "Can’t open this page of the PDF."))
        }
        let scale = CGFloat(maxPixels) / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            throw StillError(String(localized: "Can’t draw this page of the PDF."))
        }
        // 紙の白の地に描く（透明な所が黒くならないように）
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        // /Rotate は時計回り。ページの左下を、回したあとの位置へ
        switch angle {
        case 90:
            context.translateBy(x: 0, y: size.height)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: size.width, y: size.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: size.width, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else {
            throw StillError(String(localized: "Can’t draw this page of the PDF."))
        }
        return image
    }
}

/// スクリーンに貼る 1 枚（画像、または PDF の 1 ページ）
nonisolated struct StillPicture: @unchecked Sendable, Identifiable {
    let id = UUID()
    let url: URL
    let kind: StillDocument.Kind
    let page: Int
    let pageCount: Int
    let image: CGImage
    /// スクリーンの光（左・中央・右の色。部屋を照らす）
    let light: ScreenLight

    /// 横 ÷ 縦
    var aspect: Double {
        Double(image.width) / Double(max(image.height, 1))
    }
}

nonisolated struct StillError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

/// 画像の左・中央・右の 3 区画の平均の色（リニア）。動画のスクリーンの光（ScreenLightSampler）と同じ考え方
nonisolated enum StillLight {
    static let columns = 24
    static let rows = 12

    static func measure(_ image: CGImage) -> ScreenLight {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: columns,
                  height: rows,
                  bitsPerComponent: 8,
                  bytesPerRow: columns * 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return .black
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return .black
        }
        var sums = [SIMD3<Float>](repeating: .zero, count: 3)
        for row in 0..<rows {
            for column in 0..<columns {
                let pixel = data + row * columns * 4 + column * 4
                let rgb = SIMD3(Float(pixel[0]), Float(pixel[1]), Float(pixel[2])) / 255
                sums[column * 3 / columns] += SIMD3(linear(rgb.x), linear(rgb.y), linear(rgb.z))
            }
        }
        let count = Float(rows * columns / 3)
        var light = ScreenLight.black
        light.left = sums[0] / count
        light.center = sums[1] / count
        light.right = sums[2] / count
        return light
    }

    /// sRGB → リニア
    static func linear(_ value: Float) -> Float {
        value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
