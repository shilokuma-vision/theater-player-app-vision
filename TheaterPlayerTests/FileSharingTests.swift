//
//  FileSharingTests.swift
//  TheaterPlayerTests
//
//  「ファイル」App とのやり取り（Info.plist）：アプリのフォルダを「ファイル」App に出し、ファイルはその場所のまま開く。
//

import Foundation
import Testing

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
