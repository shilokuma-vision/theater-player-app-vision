//
//  AppModel.swift
//  TheaterPlayer
//
//  アプリ全体で共有する状態。TheaterPlayer で 1 つ作り、environment で各 View に渡す。
//

import Foundation
import Observation

@Observable
final class AppModel {
    /// Immersive Space の開閉の状態
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }

    /// 映画館（ImmersiveSpace）の id。openImmersiveSpace(id:) に渡す
    let immersiveSpaceID = "Theater"
    /// ライブラリ（最初のウィンドウ）の id
    let libraryWindowID = "Library"

    var immersiveSpaceState = ImmersiveSpaceState.closed
    /// 操作パネルを動かしている（そのあいだは畳まない）
    var isMovingPanel = false
    /// 操作パネルを動かし終えた回数（操作パネルが、畳むまでの待ちをやり直す）
    var panelInteraction = 0
    /// 今つないでいる映画館の舞台（同時に 1 つだけ。TheaterView が入れ替える）
    @ObservationIgnored var activeStage: TheaterStage?
    /// 舞台を作った回数（診断用）
    @ObservationIgnored var stagesCreated = 0
    /// ライブラリのウィンドウが開いているか（LibraryView が書き換える。映画館を閉じたときに開き直すかを決める）
    var isLibraryOpen = false
    /// 映画館の中から「字幕ファイルを選ぶ」を頼まれた（ライブラリのウィンドウがファイルの選択を出す）
    var requestSubtitleFile = false
    let preferences: Preferences
    let recents: RecentItems
    /// 再生（映画館を開いたときに作る）
    let player: PlayerModel

    init(preferences: Preferences = Preferences(), recents: RecentItems = RecentItems()) {
        self.preferences = preferences
        self.recents = recents
        player = PlayerModel(preferences: preferences, recents: recents)
        // コントロールセンター・AirPods・Siri からの操作も、パネルの操作と同じ入口を通す
        player.nowPlaying.connect { [weak self] command in
            self?.perform(command)
        }
    }

    /// 再生の操作を行う。操作パネル・Now Playing・スクリーンをつまむ操作など、どこからの操作もここを通す
    func perform(_ command: PlayerCommand) {
        switch command {
        case .showPanel:
            panelInteraction += 1
        default:
            player.perform(command)
        }
    }
}
