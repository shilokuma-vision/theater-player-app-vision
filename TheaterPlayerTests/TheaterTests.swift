//
//  TheaterTests.swift
//  TheaterPlayerTests
//
//  映画館の配置（アプリに入れた TheaterLayout.json）・照明の演出・設定・最近の一覧。
//

import CinemaAudio
import Foundation
import Testing
import TheaterMedia
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

    /// 座席表の列は前から並び、席は席番号の順。通路はブロックの境目（L と C、C と R）の 2 か所
    @Test func seatRowsFollowTheBlocks() throws {
        let layout = try layout()
        let rows = layout.seatRows
        #expect(rows.map(\.letter) == layout.rowLetters)
        for row in rows {
            #expect(row.seats.map(\.number) == Array(1...34))
            #expect(row.aisleBefore.count == 2)
        }
        let center = try #require(rows.first { $0.letter == "G" })
        #expect(center.aisleBefore == ["G-9", "G-27"])
        #expect(center.seats.first { $0.id == "G-9" }?.block == "C")
        #expect(center.seats.first { $0.id == "G-8" }?.block == "L")
    }

    /// 座席表の区画は、列を A〜C・D〜F・G〜J・K〜N に分け、それぞれを左・中央・右のブロックに分けた 12 個。
    /// どの席も、ちょうど 1 つの区画に入る
    @Test func seatSectionsSplitRowsAndBlocks() throws {
        let layout = try layout()
        let sections = layout.seatSections()
        #expect(sections.map(\.id) == ["L-A", "C-A", "R-A", "L-D", "C-D", "R-D", "L-G", "C-G", "R-G", "L-K", "C-K", "R-K"])
        // 同じ前後のまとまりの 3 区画は、同じ列を持つ
        #expect(sections.map { $0.rows.map(\.letter).joined() } == ["ABC", "DEF", "GHJ", "KLMN"].flatMap { Array(repeating: $0, count: 3) })
        #expect(sections.map(\.seats.count) == [24, 54, 24, 24, 54, 24, 24, 54, 24, 32, 72, 32])
        for seat in layout.seats {
            #expect(sections.filter { $0.contains(seat) }.count == 1)
            #expect(sections.filter { $0.seats.contains(seat) }.count == 1)
        }
        let center = try #require(sections.first { $0.id == "C-G" })
        #expect(center.rows.first?.seats.map(\.number) == Array(9...26))
        #expect(center.rows.allSatisfy { $0.aisleBefore.isEmpty })
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
        let level = preferences.houseLevel
        let director = LightingDirector(initialHouse: level)
        _ = director.step(deltaTime: 1, phase: .feature, hasVideo: true, preferences: preferences, light: nil)
        #expect(director.house < level)
        #expect(director.house > level * 0.7)
        for _ in 0..<10 {
            _ = director.step(deltaTime: 1, phase: .feature, hasVideo: true, preferences: preferences, light: nil)
        }
        #expect(director.house == preferences.showLevel)
    }

    /// 開場は照明を焼き付けたときより明るく、色は白のまま
    @Test func openHouseIsBrighterThanBakedAndStaysWhite() {
        let preferences = preferences()
        #expect(preferences.houseLevel > 1)
        let director = LightingDirector(initialHouse: preferences.houseLevel)
        let values = director.step(deltaTime: 0.01, phase: .lobby, hasVideo: false, preferences: preferences, light: nil)
        #expect(values.house.x > 1)
        #expect(values.house.x == values.house.z)
    }

    /// 開場を明るくしても、再生すると約 6 秒で上映中の明るさまで落ちる
    @Test func brightHouseStillDimsInAboutSixSeconds() {
        let preferences = preferences()
        let director = LightingDirector(initialHouse: preferences.houseLevel)
        for _ in 0..<5 {
            _ = director.step(deltaTime: 1, phase: .feature, hasVideo: true, preferences: preferences, light: nil)
        }
        #expect(director.house > preferences.showLevel)
        _ = director.step(deltaTime: 1.5, phase: .feature, hasVideo: true, preferences: preferences, light: nil)
        #expect(director.house == preferences.showLevel)
    }

    /// 暗くするほど暖かい色になる（青が先に減る）
    @Test func dimmedHouseLightsAreWarmer() {
        let preferences = preferences()
        preferences.houseLevel = 0.2
        let director = LightingDirector(initialHouse: 0.2)
        let values = director.step(deltaTime: 0.01, phase: .lobby, hasVideo: false, preferences: preferences, light: nil)
        #expect(values.house.x > values.house.z)
    }
}

struct PreferencesTests {
    /// 動かした操作パネルの位置を覚え、元に戻すと消す
    @Test func savesAndClearsThePanelPosition() throws {
        let suite = "PreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.panelPosition == nil)
        preferences.panelPosition = SIMD3(0.3, 1.1, -0.7)
        #expect(Preferences(defaults: defaults).panelPosition == SIMD3(0.3, 1.1, -0.7))
        preferences.panelPosition = nil
        #expect(Preferences(defaults: defaults).panelPosition == nil)
    }

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

/// 低音の既定を強めたとき（音響の設定の版 2）、前の版で保存した設定を引き上げる
struct AudioSettingsMigrationTests {
    func defaults(saving audio: CinemaAudioSettings) throws -> UserDefaults {
        let suite = "AudioSettingsMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(try JSONEncoder().encode(audio), forKey: "audio")
        return defaults
    }

    @Test func raisesTheBassSavedByTheOldVersion() throws {
        var old = CinemaAudioSettings()
        old.bassBoostDB = 4
        old.virtualBass = 0.5
        let defaults = try defaults(saving: old)
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.audio.bassBoostDB == CinemaAudioSettings().bassBoostDB)
        #expect(preferences.audio.virtualBass == CinemaAudioSettings().virtualBass)
        // 引き上げた値を保存しているので、次に読んでも同じ
        #expect(Preferences(defaults: defaults).audio.bassBoostDB == CinemaAudioSettings().bassBoostDB)
    }

    @Test func keepsBassTheUserRaised() throws {
        var old = CinemaAudioSettings()
        old.bassBoostDB = 15
        let preferences = Preferences(defaults: try defaults(saving: old))
        #expect(preferences.audio.bassBoostDB == 15)
    }
}

/// 3D（立体視）の並べ方の見分け方と、片目の縦横比
struct StereoTests {
    @Test func guessesThePackingFromTheFileName() {
        #expect(StereoPacking.guess(fromFileName: "Movie.2010.1080p.Half-SBS.mkv") == .sideBySide)
        #expect(StereoPacking.guess(fromFileName: "movie_HSBS.mp4") == .sideBySide)
        #expect(StereoPacking.guess(fromFileName: "Movie (3D Side by Side).mkv") == .sideBySide)
        #expect(StereoPacking.guess(fromFileName: "Movie.3D.HOU.mkv") == .overUnder)
        #expect(StereoPacking.guess(fromFileName: "stereo-test_TAB.mp4") == .overUnder)
        #expect(StereoPacking.guess(fromFileName: "Top-and-Bottom.mp4") == .overUnder)
        // 言葉の一部に含まれるだけの文字（"you" の "ou"・"table" の "tab"）は印にしない
        #expect(StereoPacking.guess(fromFileName: "Thank You For The Music.mp4") == nil)
        #expect(StereoPacking.guess(fromFileName: "Round Table.mkv") == nil)
    }

    @Test func eyeAspectDependsOnFullOrHalf() {
        // フルの左右（3840×1080）は片目 16:9、ハーフ（1920×1080）もそのまま 16:9
        #expect(abs(StereoPacking.sideBySide.eyeAspect(frameAspect: 3840.0 / 1080) - 16.0 / 9) < 0.001)
        #expect(abs(StereoPacking.sideBySide.eyeAspect(frameAspect: 16.0 / 9) - 16.0 / 9) < 0.001)
        // フルの上下（1920×2160）は片目 16:9、シネスコのフルの上下（2.39 を縦に 2 つ）も 2.39 に戻る
        #expect(abs(StereoPacking.overUnder.eyeAspect(frameAspect: 1920.0 / 2160) - 16.0 / 9) < 0.001)
        #expect(abs(StereoPacking.overUnder.eyeAspect(frameAspect: 2.39 / 2) - 2.39) < 0.001)
        // 空間ビデオの形式は片目の層の大きさなので、そのまま
        #expect(StereoPacking.multiview.eyeAspect(frameAspect: 16.0 / 9) == 16.0 / 9)
    }

    @Test func modeChoosesTheContainerFirstThenTheName() {
        #expect(StereoMode.auto.resolve(track: .multiview, fileName: "IMG_0001.MOV") == .multiview)
        #expect(StereoMode.auto.resolve(track: .mono, fileName: "clip_SBS.mp4") == .sideBySide)
        #expect(StereoMode.auto.resolve(track: .mono, fileName: "clip.mp4") == .mono)
        #expect(StereoMode.off.resolve(track: .sideBySide, fileName: "clip_SBS.mp4") == .mono)
        #expect(StereoMode.overUnder.resolve(track: .mono, fileName: "clip.mp4") == .overUnder)
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
