//
//  FileSharingTests.swift
//  TheaterPlayerTests
//
//  「ファイル」App とのやり取り：アプリのフォルダを「ファイル」App に出し（Info.plist・空なら案内を置く）、ファイルはその場所のまま開く。
//

import Foundation
import Testing
@testable import TheaterPlayer

struct FileSharingTests {
    let info = Bundle.main.infoDictionary ?? [:]

    /// アプリの Documents を「ファイル」App の「この Apple Vision Pro 内」に「TheaterPlayer」として出す。
    /// 2 つそろわないと、フォルダが「ファイル」App に出ない
    @Test func documentsFolderIsSharedWithTheFilesApp() {
        #expect(info["UIFileSharingEnabled"] as? Bool == true)
        #expect(info["LSSupportsOpeningDocumentsInPlace"] as? Bool == true)
    }

    /// 「ファイル」App から開ける（「このアプリで開く」に出る）種類：動画・音楽・画像・PDF
    @Test func documentTypesCoverEverythingTheTheaterShows() throws {
        let types = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let contentTypes = Set(types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        for required in ["public.movie", "public.audio", "public.image", "com.adobe.pdf"] {
            #expect(contentTypes.contains(required))
        }
        // 開くだけで書き換えない
        #expect(types.allSatisfy { $0["CFBundleTypeRole"] as? String == "Viewer" })
    }
}

/// 「ファイル」App に出すフォルダ：空なら案内を置き、何か入っていれば何もしない
struct SharedFolderTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SharedFolderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// 空のフォルダには案内を置く（空だと「ファイル」App に出ない）
    @Test func emptyFolderGetsTheGuide() throws {
        let folder = try folder()
        SharedFolder.prepare(folder)
        #expect(try names(in: folder) == [SharedFolder.guideName])
        let text = try String(contentsOf: folder.appendingPathComponent(SharedFolder.guideName), encoding: .utf8)
        #expect(text == SharedFolder.guideText)
    }

    /// まだ無いフォルダは作ってから案内を置く
    @Test func missingFolderIsCreated() throws {
        let folder = try folder().appendingPathComponent("Documents", isDirectory: true)
        SharedFolder.prepare(folder)
        #expect(try names(in: folder) == [SharedFolder.guideName])
    }

    /// ファイルが入っていれば何もしない（消された案内を置き直さない）
    @Test func folderWithFilesIsLeftAlone() throws {
        let folder = try folder()
        try Data().write(to: folder.appendingPathComponent("movie.mkv"))
        SharedFolder.prepare(folder)
        #expect(try names(in: folder) == ["movie.mkv"])
    }

    /// 隠しファイルだけなら空とみなす（「ファイル」App には出ない）
    @Test func hiddenFilesDoNotCount() throws {
        let folder = try folder()
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        SharedFolder.prepare(folder)
        #expect(try names(in: folder) == [".DS_Store", SharedFolder.guideName])
    }

    /// 起動を繰り返しても、案内は 1 つのまま
    @Test func preparingTwiceKeepsOneGuide() throws {
        let folder = try folder()
        SharedFolder.prepare(folder)
        SharedFolder.prepare(folder)
        #expect(try names(in: folder) == [SharedFolder.guideName])
    }
}
