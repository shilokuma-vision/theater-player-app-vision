//
//  RecentItems.swift
//  TheaterPlayer
//
//  最近再生したファイル。「ファイル」App で選んだファイルはアプリの外にあるので、ブックマーク（場所の手がかり）で開き直す。
//  前回の続きから再生できるよう、再生した位置も持つ。Application Support/recents.json に保存する。
//

import Foundation
import Observation

@Observable
final class RecentItems {
    struct Item: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var bookmark: Data
        /// 前回やめた位置（秒）
        var position: Double = 0
        var duration: Double?
        var isAudioOnly = false
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

    /// 開いたファイルを先頭に入れる（同じファイルなら位置を引き継ぐ）
    @discardableResult
    func add(url: URL) -> Item? {
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return nil
        }
        let name = url.lastPathComponent
        var item = items.first { $0.name == name } ?? Item(name: name, bookmark: bookmark)
        item.bookmark = bookmark
        item.playedAt = Date()
        items.removeAll { $0.id == item.id }
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

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
