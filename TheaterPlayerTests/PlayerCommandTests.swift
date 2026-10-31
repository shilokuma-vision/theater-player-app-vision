//
//  PlayerCommandTests.swift
//  TheaterPlayerTests
//
//  再生の操作（PlayerCommand）の動く先と、AppModel・PlayerModel の入口。
//

import Foundation
import Testing
@testable import TheaterPlayer

struct PlayerCommandSeekTests {
    /// 0:00・10:00・20:00 に始まる 3 つのチャプター
    let chapters: [Double] = [0, 600, 1_200]

    /// スキップは、頭と終わりの間に収める
    @Test func skipStaysWithinTheMovie() {
        #expect(PlayerCommand.skip(by: 30).seekTarget(from: 100, duration: 1_800, chapterStarts: []) == 130)
        #expect(PlayerCommand.skip(by: -10).seekTarget(from: 4, duration: 1_800, chapterStarts: []) == 0)
        #expect(PlayerCommand.skip(by: 30).seekTarget(from: 1_790, duration: 1_800, chapterStarts: []) == 1_800)
        // 長さが分からないときは、先へは制限しない
        #expect(PlayerCommand.skip(by: 30).seekTarget(from: 100, duration: 0, chapterStarts: []) == 130)
    }

    @Test func seekStaysWithinTheMovie() {
        #expect(PlayerCommand.seek(to: 500).seekTarget(from: 0, duration: 1_800, chapterStarts: []) == 500)
        #expect(PlayerCommand.seek(to: -5).seekTarget(from: 0, duration: 1_800, chapterStarts: []) == 0)
        #expect(PlayerCommand.seek(to: 2_000).seekTarget(from: 0, duration: 1_800, chapterStarts: []) == 1_800)
    }

    /// 次のチャプター：今より後に始まるチャプターへ。最後のチャプターでは動かない
    @Test func nextChapterGoesToTheFollowingStart() {
        let next = PlayerCommand.nextChapter
        #expect(next.seekTarget(from: 0, duration: 1_800, chapterStarts: chapters) == 600)
        #expect(next.seekTarget(from: 700, duration: 1_800, chapterStarts: chapters) == 1_200)
        #expect(next.seekTarget(from: 1_300, duration: 1_800, chapterStarts: chapters) == nil)
        // 並びが前後していても、時刻の順に見る
        #expect(next.seekTarget(from: 0, duration: 1_800, chapterStarts: [1_200, 0, 600]) == 600)
        #expect(next.seekTarget(from: 0, duration: 1_800, chapterStarts: []) == nil)
    }

    /// シークの直後は位置がチャプターの始まりから少しずれる。続けて「次へ」を押しても、同じ始まりへ戻らない
    @Test func nextChapterSkipsTheChapterJustReached() {
        let next = PlayerCommand.nextChapter
        #expect(next.seekTarget(from: 599.6, duration: 1_800, chapterStarts: chapters) == 1_200)
        #expect(next.seekTarget(from: 600.2, duration: 1_800, chapterStarts: chapters) == 1_200)
    }

    /// 長さより後に始まるチャプター（ファイルの情報の誤り）へは動かない
    @Test func nextChapterIgnoresStartsPastTheEnd() {
        #expect(PlayerCommand.nextChapter.seekTarget(from: 700, duration: 1_000, chapterStarts: chapters) == nil)
    }

    /// 前のチャプター：今のチャプターに入って 3 秒より後なら、今のチャプターの始まりへ。3 秒以内なら、1 つ前へ
    @Test func previousChapterRestartsOrGoesBack() {
        let previous = PlayerCommand.previousChapter
        #expect(previous.seekTarget(from: 700, duration: 1_800, chapterStarts: chapters) == 600)
        #expect(previous.seekTarget(from: 602, duration: 1_800, chapterStarts: chapters) == 0)
        // シークの直後（始まりの少し手前）も、今のチャプターの始まりにいるとみなす
        #expect(previous.seekTarget(from: 1_199.6, duration: 1_800, chapterStarts: chapters) == 600)
        // 最初のチャプターの中では頭へ
        #expect(previous.seekTarget(from: 2, duration: 1_800, chapterStarts: chapters) == 0)
        #expect(previous.seekTarget(from: 100, duration: 1_800, chapterStarts: chapters) == 0)
    }

    /// 最初のチャプターより前（チャプターが 0 秒から始まらないファイル）では頭へ。チャプターが無ければ動かない
    @Test func previousChapterBeforeTheFirstChapter() {
        #expect(PlayerCommand.previousChapter.seekTarget(from: 3, duration: 1_800, chapterStarts: [30, 600]) == 0)
        #expect(PlayerCommand.previousChapter.seekTarget(from: 100, duration: 1_800, chapterStarts: []) == nil)
    }

    /// 位置を動かさない操作
    @Test func otherCommandsDoNotSeek() {
        for command in [PlayerCommand.togglePlay, .play, .pause, .setRate(1.5), .startNow, .changeVolume(by: 0.1), .showPanel] {
            #expect(command.seekTarget(from: 100, duration: 1_800, chapterStarts: chapters) == nil)
        }
    }
}

struct PlayerCommandVolumeTests {
    /// 音量は 0〜上限に収め、0.01 刻みに丸める（足し続けても端数がたまらない）
    @Test func volumeStaysWithinRangeAndRounds() {
        #expect(PlayerCommand.volume(1, changedBy: 0.1, maximum: 1.5) == 1.1)
        #expect(PlayerCommand.volume(1.45, changedBy: 0.1, maximum: 1.5) == 1.5)
        #expect(PlayerCommand.volume(0.05, changedBy: -0.1, maximum: 1.5) == 0)
        var volume = 0.0
        for _ in 0..<7 {
            volume = PlayerCommand.volume(volume, changedBy: 0.1, maximum: 1.5)
        }
        #expect(volume == 0.7)
    }
}

@MainActor
struct PlayerCommandRoutingTests {
    func makeAppModel() throws -> AppModel {
        let defaults = try #require(UserDefaults(suiteName: "PlayerCommandRoutingTests.\(UUID().uuidString)"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recents = RecentItems(file: folder.appendingPathComponent("recents.json"))
        return AppModel(preferences: Preferences(defaults: defaults), recents: recents)
    }

    /// 「パネルを出す」は、操作パネルに開き直させる（ControlPanel が panelInteraction の変化を見る）
    @Test func showPanelAsksThePanelToOpen() throws {
        let appModel = try makeAppModel()
        let before = appModel.panelInteraction
        appModel.perform(.showPanel)
        #expect(appModel.panelInteraction == before + 1)
    }

    /// 何も開いていないときの再生の操作は、何もしない（落ちない・位置も速さも変わらない）
    @Test func playbackCommandsWithoutMediaDoNothing() throws {
        let appModel = try makeAppModel()
        let commands: [PlayerCommand] = [
            .togglePlay, .play, .pause, .skip(by: 30), .seek(to: 100), .nextChapter, .previousChapter, .setRate(2), .startNow
        ]
        for command in commands {
            appModel.perform(command)
        }
        #expect(appModel.player.currentTime == 0)
        #expect(!appModel.player.isPlaying)
        #expect(appModel.player.rate == 1)
    }

    /// 音量は、何も開いていなくても変えられ、設定に残る。上限・0 で止まる
    @Test func volumeChangesWithoutMedia() throws {
        let appModel = try makeAppModel()
        appModel.preferences.volume = 1
        appModel.perform(.changeVolume(by: 0.1))
        #expect(appModel.preferences.volume == 1.1)
        // 上限まで上げて、さらに上げても上限のまま。0 まで下げて、さらに下げても 0 のまま
        for _ in 0...Int(Preferences.maxVolume * 10) {
            appModel.perform(.changeVolume(by: 0.1))
        }
        #expect(appModel.preferences.volume == Preferences.maxVolume)
        for _ in 0...Int(Preferences.maxVolume * 10) + 1 {
            appModel.perform(.changeVolume(by: -0.1))
        }
        #expect(appModel.preferences.volume == 0)
    }
}
