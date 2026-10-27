//
//  TheaterTests.swift
//  TheaterPlayerTests
//
//  映画館の配置（アプリに入れた TheaterLayout.json）・照明の演出・設定・最近の一覧。
//

import CinemaAudio
import Foundation
import Testing
@testable import TheaterPlayer
import TheaterScene

struct TheaterLayoutTests {
    func layout() throws -> TheaterLayout {
        let url = try #require(Bundle.main.url(forResource: "TheaterLayout", withExtension: "json"))
        return try TheaterLayout.load(from: url)
    }

    /// 13 列 × 34 席。I の列は無い。既定の席（G-17）がある
    @Test func seatsCoverTheWholeTheater() throws {
        let layout = try layout()
        #expect(layout.seats.count == 13 * 34)
        #expect(layout.rowLetters == ["A", "B", "C", "D", "E", "F", "G", "H", "J", "K", "L", "M", "N"])
        let seat = try #require(layout.seat(id: Preferences.defaultSeat))
        #expect(seat.eye.y > seat.floor.y + 1)
        // 座席はスクリーン（-Z）より手前にある
        #expect(seat.floor.z > layout.screen.center.z)
    }

    /// 後ろの列ほど床が高い（スタジアム形式）
    @Test func rowsRiseTowardTheBack() throws {
        let layout = try layout()
        let floors = layout.rowLetters.compactMap { row in layout.seats.first { $0.row == row }?.floor.y }
        #expect(floors == floors.sorted())
        #expect((floors.last ?? 0) > 4)
    }

    /// スピーカーの系統はすべて映画館の音響処理の系統で、スクリーンの裏とサブウーファーがある
    @Test func speakersUseKnownBuses() throws {
        let buses = try layout().emitters.map(\.bus)
        #expect(buses.allSatisfy { CinemaBus(rawValue: $0) != nil })
        for required in ["L", "C", "R", "LFE", "Lss", "Rss", "Lrs", "Rrs", "Ltf", "Rtf", "Ltr", "Rtr"] {
            #expect(buses.contains(required))
        }
    }

    /// 座席のひな形を置く単位は、座席 1 つに 1 つ（＋ブロックの左端の袖）
    @Test func unitsMatchSeats() throws {
        let layout = try layout()
        let seated = layout.units.filter { $0.number != nil }
        #expect(seated.count == layout.seats.count)
        #expect(Set(layout.units.map(\.tile)).count == layout.units.count)
    }
}

@MainActor
struct LightingDirectorTests {
    func preferences() -> Preferences {
        Preferences(defaults: UserDefaults(suiteName: "LightingDirectorTests.\(UUID().uuidString)") ?? .standard)
    }

    /// 再生を始めると、客電がゆっくり（数秒かけて）落ちる
    @Test func houseLightsDimSlowlyWhenPlaying() {
        let preferences = preferences()
        let director = LightingDirector(initialHouse: 0.8)
        _ = director.step(deltaTime: 1, playing: true, hasVideo: true, preferences: preferences, light: nil)
        #expect(director.house < 0.8)
        #expect(director.house > 0.5)
        for _ in 0..<10 {
            _ = director.step(deltaTime: 1, playing: true, hasVideo: true, preferences: preferences, light: nil)
        }
        #expect(director.house == preferences.showLevel)
    }

    /// 暗くするほど暖かい色になる（青が先に減る）
    @Test func dimmedHouseLightsAreWarmer() {
        let preferences = preferences()
        preferences.houseLevel = 0.2
        let director = LightingDirector(initialHouse: 0.2)
        let values = director.step(deltaTime: 0.01, playing: false, hasVideo: false, preferences: preferences, light: nil)
        #expect(values.house.x > values.house.z)
    }
}

struct PreferencesTests {
    @Test func savesAndRestoresTheSeatAndAudioSettings() throws {
        let suite = "PreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.seatID == Preferences.defaultSeat)
        preferences.seatID = "K-20"
        preferences.audio.bassBoostDB = 9
        let restored = Preferences(defaults: defaults)
        #expect(restored.seatID == "K-20")
        #expect(restored.audio.bassBoostDB == 9)
    }

    /// 部屋の響きも保存する。以前 @AppStorage("room") で保存した値も読む
    @Test func savesAndRestoresTheRoom() throws {
        let suite = "PreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SpatialSpeakers.Room.rich.rawValue, forKey: "room")
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.room == .rich)
        preferences.room = .dry
        #expect(Preferences(defaults: defaults).room == .dry)
    }
}

struct RecentItemsTests {
    @Test func resumesOnlyInTheMiddle() {
        var item = RecentItems.Item(name: "movie.mkv", bookmark: Data())
        item.duration = 7_200
        item.position = 5
        #expect(item.resumePosition == nil)
        item.position = 1_800
        #expect(item.resumePosition == 1_800)
        item.position = 7_170
        #expect(item.resumePosition == nil)
    }

    /// 同じ名前でも、別のフォルダーのファイルは別の項目にする。同じファイルを開き直したら、同じ項目を先頭へ
    @Test func distinguishesFilesWithTheSameName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RecentItemsTests.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try makeFile(folder.appendingPathComponent("Season1/01.mkv"))
        let second = try makeFile(folder.appendingPathComponent("Season2/01.mkv"))
        let recents = RecentItems(file: folder.appendingPathComponent("recents.json"))
        let firstItem = try #require(recents.add(url: first))
        recents.update(firstItem.id, position: 600, duration: 1_800, isAudioOnly: false)
        let secondItem = try #require(recents.add(url: second))
        #expect(recents.items.count == 2)
        #expect(secondItem.id != firstItem.id)
        #expect(secondItem.position == 0)
        let reopened = try #require(recents.add(url: first))
        #expect(reopened.id == firstItem.id)
        #expect(reopened.position == 600)
        #expect(recents.items.map(\.id) == [firstItem.id, secondItem.id])
    }

    /// 一覧から開いたときは、その項目を書き換える（ファイルが動いて、ブックマークから別の場所が返ってきても）
    @Test func updatesTheChosenItem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RecentItemsTests.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try makeFile(folder.appendingPathComponent("movie.mkv"))
        let moved = try makeFile(folder.appendingPathComponent("Moved/movie (1).mkv"))
        let recents = RecentItems(file: folder.appendingPathComponent("recents.json"))
        let item = try #require(recents.add(url: file))
        let updated = try #require(recents.add(url: moved, replacing: item.id))
        #expect(updated.id == item.id)
        #expect(updated.name == "movie (1).mkv")
        #expect(updated.path == RecentItems.path(of: moved))
        #expect(recents.items.count == 1)
    }

    private func makeFile(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: url)
        return url
    }

    @Test func formatsClockTime() {
        #expect(TimeFormat.clock(65) == "1:05")
        #expect(TimeFormat.clock(3_725) == "1:02:05")
        #expect(TimeFormat.clock(.nan) == "--:--")
    }
}
