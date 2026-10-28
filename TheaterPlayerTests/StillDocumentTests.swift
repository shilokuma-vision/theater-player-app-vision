//
//  StillDocumentTests.swift
//  TheaterPlayerTests
//
//  静止画（画像・PDF）：形式の見分け・縮小・ページの縦横比と向き・スクリーンの光・ページの移動・最近の一覧。
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import TheaterPlayer
import UniformTypeIdentifiers

/// テスト用のファイル（一時フォルダーに作る）
enum StillFixtures {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StillDocumentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 左半分が赤・右半分が青の PNG
    static func png(width: Int, height: Int, in folder: URL) throws -> URL {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let image = try #require(context.makeImage())
        let url = folder.appendingPathComponent("picture.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// 2 ページの PDF（どちらも 600 × 800 の縦で、左下に黒い四角）。2 ページ目は /Rotate 90（時計回り）で横に見せる。
    /// CGPDFContext では回転を指定できないので、短い PDF を直接書く（参照表が無くても CGPDFDocument は読める）
    static func pdf(in folder: URL) throws -> URL {
        let stream = "0 0 100 100 re f\n"
        let text = """
        %PDF-1.4
        1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        2 0 obj << /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >> endobj
        3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Contents 5 0 R >> endobj
        4 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Rotate 90 /Contents 5 0 R >> endobj
        5 0 obj << /Length \(stream.utf8.count) >>
        stream
        \(stream)endstream
        endobj
        trailer << /Root 1 0 R /Size 6 >>
        %%EOF

        """
        let url = folder.appendingPathComponent("document.pdf")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// 画像の (x, y)（上から数える）の赤の値（0〜255）
    static func red(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        let width = image.width
        let height = image.height
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // メモリの 0 行目が画像の上
        return data[y * width * 4 + x * 4]
    }
}

struct StillDocumentTests {
    @Test(arguments: [
        ("photo.png", StillDocument.Kind.image), ("photo.JPG", .image), ("photo.heic", .image), ("anim.gif", .image),
        ("picture.webp", .image), ("slides.pdf", .pdf)
    ])
    func recognizesImagesAndPDF(name: String, kind: StillDocument.Kind) {
        #expect(StillDocument.kind(of: URL(fileURLWithPath: "/tmp/\(name)")) == kind)
    }

    @Test(arguments: ["movie.mkv", "movie.mp4", "song.flac", "song.mp3", "notes.txt"])
    func leavesMediaAndOtherFilesAlone(name: String) {
        #expect(StillDocument.kind(of: URL(fileURLWithPath: "/tmp/\(name)")) == nil)
    }

    /// 大きな画像は、長い辺を上限まで縮める（縦横比はそのまま）
    @Test func shrinksLargeImages() throws {
        let folder = try StillFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try StillFixtures.png(width: 6_000, height: 1_500, in: folder)
        let document = try StillDocument.open(url)
        #expect(document.kind == .image)
        #expect(document.pageCount == 1)
        let picture = try document.render(page: 0, maxPixels: 2_048)
        #expect(max(picture.image.width, picture.image.height) == 2_048)
        #expect(abs(picture.aspect - 4) < 0.01)
    }

    /// スクリーンの光：画像の左は赤、右は青
    @Test func measuresTheScreenLightFromTheImage() throws {
        let folder = try StillFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = try StillDocument.open(StillFixtures.png(width: 600, height: 300, in: folder)).render(page: 0)
        #expect(picture.light.left.x > 0.9)
        #expect(picture.light.left.z < 0.05)
        #expect(picture.light.right.z > 0.9)
        #expect(picture.light.right.x < 0.05)
    }

    /// PDF：ページの数と、ページごとの縦横比（/Rotate 90 のページは横長になる）
    @Test func rendersPDFPagesWithTheirOrientation() throws {
        let folder = try StillFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try StillDocument.open(StillFixtures.pdf(in: folder))
        #expect(document.kind == .pdf)
        #expect(document.pageCount == 2)
        let first = try document.render(page: 0, maxPixels: 800)
        #expect(abs(first.aspect - 0.75) < 0.01)
        #expect(first.image.height == 800)
        // 回さないページ：黒い四角は左下
        #expect(try StillFixtures.red(first.image, x: 5, y: first.image.height - 5) < 50)
        #expect(try StillFixtures.red(first.image, x: 5, y: 5) > 200)
        let second = try document.render(page: 1, maxPixels: 800)
        #expect(abs(second.aspect - 4.0 / 3.0) < 0.01)
        // 時計回りに回したページ：左下の四角は左上へ
        #expect(try StillFixtures.red(second.image, x: 5, y: 5) < 50)
        #expect(try StillFixtures.red(second.image, x: 5, y: second.image.height - 5) > 200)
    }

    @Test func refusesFilesThatAreNotStills() {
        #expect(throws: StillError.self) {
            try StillDocument.open(URL(fileURLWithPath: "/tmp/movie.mkv"))
        }
    }
}

@MainActor
struct StillPlaybackTests {
    struct Setup {
        let player: PlayerModel
        let recents: RecentItems
        let folder: URL
    }

    func makePlayer() throws -> Setup {
        let folder = try StillFixtures.folder()
        let defaults = try #require(UserDefaults(suiteName: "StillPlaybackTests.\(UUID().uuidString)"))
        let recents = RecentItems(file: folder.appendingPathComponent("recents.json"))
        return Setup(player: PlayerModel(preferences: Preferences(defaults: defaults), recents: recents), recents: recents, folder: folder)
    }

    /// PDF を開いてページを送り、最近の一覧に種類と見ていたページが残る。端では止まる
    @Test func pagesThroughAPDFAndRemembersThePage() async throws {
        let setup = try makePlayer()
        let (player, recents, folder) = (setup.player, setup.recents, setup.folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        await player.open(url: try StillFixtures.pdf(in: folder))
        let first = try #require(player.still)
        #expect(first.page == 0)
        #expect(first.pageCount == 2)
        #expect(player.hasMedia)
        #expect(!player.hasPlayback)
        await player.nextPage()
        #expect(player.still?.page == 1)
        await player.nextPage()
        #expect(player.still?.page == 1)
        let item = try #require(recents.items.first)
        #expect(item.stillKind == .pdf)
        #expect(item.page == 1)
        // 開き直すと、前回のページから
        player.close()
        #expect(player.still == nil)
        await player.open(item)
        #expect(player.still?.page == 1)
        player.close()
    }

    @Test func showsAnImage() async throws {
        let setup = try makePlayer()
        let (player, recents, folder) = (setup.player, setup.recents, setup.folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        await player.open(url: try StillFixtures.png(width: 1_920, height: 1_080, in: folder))
        let still = try #require(player.still)
        #expect(still.kind == .image)
        #expect(abs(still.aspect - 16.0 / 9.0) < 0.01)
        #expect(player.title == "picture")
        #expect(recents.items.first?.stillKind == .image)
        player.close()
    }
}
