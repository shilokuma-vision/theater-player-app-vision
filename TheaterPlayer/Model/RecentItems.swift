//
//  RecentItems.swift
//  TheaterPlayer
//
//  最近再生したファイル。「ファイル」App で選んだファイルはアプリの外にあるので、ブックマーク（場所の手がかり）で開き直す。
//  前回の続きから再生できるよう、再生した位置も持つ（PDF は見ていたページ）。Application Support/recents.json に保存する。
//

import Foundation
import Observation

@Observable
final class RecentItems {
    struct Item: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var bookmark: Data
        /// ファイルの場所（同じファイルかを比べる。名前だけだと Season1/01.mkv と Season2/01.mkv を取り違える）。
        /// 場所を持つ前に保存した項目では nil
        var path: String?
        /// 前回やめた位置（秒）
        var position: Double = 0
        var duration: Double?
        var isAudioOnly = false
        /// 画像・PDF なら、その種類（動画・音楽は nil。これを持つ前に保存した項目も nil）
        var stillKind: StillDocument.Kind?
        /// PDF の、前回見ていたページ（0 から）
        var page: Int?
        var playedAt = Date()

        /// 続きから再生する位置（最後の 1 分は最初から）
        var resumePosition: Double? {
            guard position > 10 else {
                return nil
            }
            if let duration, position > duration - 60 {
                return nil
            }
            return position
        }
    }

    private(set) var items: [Item] = []
    private let file: URL

    init(file: URL? = nil) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.file = file ?? folder.appendingPathComponent("recents.json")
        if let data = try? Data(contentsOf: self.file), let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded
        }
    }

    /// 開いたファイルを先頭に入れる（同じファイルなら位置を引き継ぐ）。一覧から開いたときは、その項目（id）を書き換える
    @discardableResult
    func add(url: URL, replacing id: UUID? = nil) -> Item? {
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return nil
        }
        let path = Self.path(of: url)
        let existing = items.first { $0.id == id } ?? items.first { ($0.path ?? Self.resolvedPath($0.bookmark)) == path }
        var item = existing ?? Item(name: url.lastPathComponent, bookmark: bookmark)
        item.name = url.lastPathComponent
        item.bookmark = bookmark
        item.path = path
        item.playedAt = Date()
        // 同じ場所の項目が別にあれば（一覧の項目を開き直したら、別の項目と同じファイルだった）1 つにまとめる
        items.removeAll { $0.id == item.id || $0.path == path }
        items.insert(item, at: 0)
        items = Array(items.prefix(30))
        save()
        return item
    }

    func update(_ id: UUID, position: Double, duration: Double?, isAudioOnly: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        items[index].position = position
        items[index].duration = duration
        items[index].isAudioOnly = isAudioOnly
        save()
    }

    /// 画像・PDF の種類と、見ているページを書く
    func updateStill(_ id: UUID, kind: StillDocument.Kind, page: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        items[index].stillKind = kind
        items[index].page = page
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    /// ブックマークからファイルの場所を戻す（古くなっていれば作り直す）
    func resolve(_ item: Item) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: item.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
           let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].bookmark = fresh
            save()
        }
        return url
    }

    /// 比べるためのファイルの場所
    static func path(of url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// 場所を持たない古い項目の場所（ブックマークから引く。比べるだけなので、外部ストレージをつなぎに行かない）
    private static func resolvedPath(_ bookmark: Data) -> String? {
        var stale = false
        let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
        return (try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)).map(path)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
