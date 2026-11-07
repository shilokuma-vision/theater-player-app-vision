//
//  ScreenshotDemo.swift
//  TheaterPlayer
//
//  App Store 用スクリーンショットの撮影モード。
//  Tools/capture_screenshots.sh が次の起動引数でアプリを起動し、目的の画面をデモデータで開かせる。
//
//    -screenshot-demo -screenshot-scene <Scene の rawValue> -AppleLanguages (<言語>) -AppleLocale <ロケール>
//
//  撮影モードは、撮影のビルド（capture_screenshots.sh が SWIFT_ACTIVE_COMPILATION_CONDITIONS に SCREENSHOT_DEMO を足す）にだけ入る。
//  App Store に出すビルドでは scene がいつも nil で、起動引数を渡しても何も起きない。
//
//  画面を足すときは、Scene に case を足し、下の extension で開き方（映画館に入るか・パネルのページ・席・明るさ）を決め、
//  AppStore/screenshots.json の scenes に同じ rawValue を足す（突き合わせは Tools/app_store_config.py が行う）。
//  デモデータは実データと混ざらないよう、撮影モードのときだけ別の UserDefaults と一時フォルダに用意する。
//  映る映像（ScreenshotMovie）と一覧のファイル名は、外部の素材を使わずに自分で作ったもの。
//

import Foundation
import SwiftUI
#if SCREENSHOT_DEMO
import TheaterMedia
#endif

enum ScreenshotDemo {
    /// 撮る画面。rawValue が AppStore/screenshots.json の scene と対応する
    enum Scene: String {
        case theater
        case controls
        case seats
        case lobby
        case lighting
        case library
    }

    /// 撮影モードで開く画面。撮影のビルドでないとき・撮影モードでないとき・知らない値を渡されたときは nil
    static let scene: Scene? = {
        #if SCREENSHOT_DEMO
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-screenshot-demo"),
              let index = arguments.firstIndex(of: "-screenshot-scene"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return Scene(rawValue: arguments[index + 1])
        #else
        nil
        #endif
    }()
}

extension ScreenshotDemo.Scene {
    /// 映画館に入って撮る（ライブラリは入らない）
    var entersTheater: Bool {
        self != .library
    }

    /// スクリーンに動画を映す（上映前の場内は何も映さない）
    var showsMovie: Bool {
        entersTheater && self != .lobby
    }

    /// 操作パネルのはじめのページ。nil ならパネルを畳んでおく
    var panelPage: ControlPanel.Page? {
        switch self {
        case .controls:
            .main
        case .seats:
            .seats
        case .lighting:
            .lighting
        case .theater, .lobby, .library:
            nil
        }
    }

    /// 操作パネルの位置。Simulator の視点は立った目の高さなので、ひざの上ではなく、スクリーンの下の端に重なる高さに置く
    var panelPosition: SIMD3<Float>? {
        panelPage == nil ? nil : SIMD3(0, 1.46, -0.9)
    }

    /// 座る席。映画館の全体を見せる場面は後ろの席、パネルを見せる場面はスクリーンが大きく見える中央の席
    var seatID: String {
        switch self {
        case .theater:
            "K-17"
        case .lobby:
            "N-18"
        case .controls, .seats, .lighting, .library:
            Preferences.defaultSeat
        }
    }

    /// 止めているときの客電。上映中らしく見せる場面は暗くする（真っ暗だと客席が写らないので、少しだけ残す）。
    /// 照明のページを見せる場面は、パネルで明るさを変えたと分かるよう、少し明るくする
    var houseLevel: Double {
        switch self {
        case .theater, .controls, .seats:
            0.25
        case .lighting:
            1.2
        case .lobby, .library:
            Preferences.defaultHouseLevel
        }
    }

    /// 再生中の客電（「照明」のページに出る値）
    var showLevel: Double {
        self == .lighting ? 0.08 : 0
    }
}

#if SCREENSHOT_DEMO
extension ScreenshotDemo {
    /// デモデータを置くフォルダ（アプリの一時フォルダの中）
    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotDemo", isDirectory: true)
    }

    /// 撮影モードの AppModel。設定と最近の一覧は、実データと混ざらないよう別の UserDefaults と一時フォルダに置き、起動のたびに作り直す
    static func makeAppModel() -> AppModel? {
        guard let scene else {
            return nil
        }
        let suite = "jp.shilokuma.TheaterPlayer.ScreenshotDemo"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let preferences = Preferences(defaults: defaults)
        preferences.seatID = scene.seatID
        preferences.houseLevel = scene.houseLevel
        preferences.showLevel = scene.showLevel
        // 開演の流れ（ブザー・暗転・幕）を挟まずに、すぐに映す（動画を開いたら、既定の入に戻す）
        preferences.showtime = false
        let library = folder.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.removeItem(at: library)
        let recents = RecentItems(file: library.appendingPathComponent("recents.json"))
        if scene == .library {
            fillRecents(recents, in: library)
        }
        return AppModel(preferences: preferences, recents: recents)
    }

    /// 最近の一覧の 1 行
    private struct DemoItem {
        var name: String
        var position: Double = 0
        var duration: Double?
        var isAudioOnly = false
        /// 画像・PDF の種類と、PDF の見ていたページ
        var still: StillDocument.Kind?
        var page = 0
    }

    /// 最近の一覧に、動画・音楽・PDF・画像を並べる（中身の無いファイルを作り、続きの位置と長さを書く）。
    /// ウィンドウの既定の大きさで、一覧が途中で切れない数にする
    private static func fillRecents(_ recents: RecentItems, in library: URL) {
        let names = Names.current
        let items = [
            DemoItem(name: names.movie + ".mp4", position: ScreenshotMovie.position, duration: ScreenshotMovie.duration),
            DemoItem(name: names.recital + ".flac", position: 1_395, duration: 3_840, isAudioOnly: true),
            DemoItem(name: names.program + ".pdf", still: .pdf, page: 2),
            DemoItem(name: names.aurora + ".heic", still: .image)
        ]
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        // 一覧は新しく開いた順なので、下の物から入れる
        for item in items.reversed() {
            let url = library.appendingPathComponent(item.name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            guard let added = recents.add(url: url) else {
                continue
            }
            if let kind = item.still {
                recents.updateStill(added.id, kind: kind, page: item.page)
            } else {
                recents.update(added.id, position: item.position, duration: item.duration, isAudioOnly: item.isAudioOnly)
            }
        }
    }

    /// スクリーンに映す動画の場所（題名は撮る言語に合わせる）
    static var movieURL: URL {
        folder.appendingPathComponent("Movie", isDirectory: true).appendingPathComponent(Names.current.movie + ".mp4")
    }

    /// 撮る言語ごとの、題名・ファイル名。自分で付けた名前で、実在する作品の題名は使わない
    struct Names {
        var movie: String
        var recital: String
        var aurora: String
        var program: String

        /// アプリが今使っている言語（-AppleLanguages で渡した言語）の名前。知らない言語なら英語
        static var current: Names {
            Bundle.main.preferredLocalizations.first.flatMap { all[$0] } ?? english
        }

        private static let english = Names(
            movie: "Sunset Hills",
            recital: "Piano Recital",
            aurora: "Northern Lights",
            program: "Recital Program"
        )

        private static let all: [String: Names] = [
            "en": english,
            "ja": Names(
                movie: "夕焼けの丘",
                recital: "ピアノの発表会",
                aurora: "オーロラ",
                program: "発表会のプログラム"
            ),
            "zh-Hans": Names(
                movie: "夕阳山丘",
                recital: "钢琴演奏会",
                aurora: "北极光",
                program: "演奏会节目单"
            ),
            "zh-Hant": Names(
                movie: "夕陽山丘",
                recital: "鋼琴演奏會",
                aurora: "北極光",
                program: "演奏會節目單"
            ),
            "ko": Names(
                movie: "노을 언덕",
                recital: "피아노 발표회",
                aurora: "오로라",
                program: "발표회 프로그램"
            ),
            "de": Names(
                movie: "Hügel im Abendrot",
                recital: "Klaviervorspiel",
                aurora: "Polarlicht",
                program: "Programmheft"
            ),
            "fr": Names(
                movie: "Collines au couchant",
                recital: "Récital de piano",
                aurora: "Aurore boréale",
                program: "Programme du récital"
            )
        ]
    }

    /// 場面が整った印（Tools/capture_screenshots.sh が、アプリのデータのフォルダの tmp/ScreenshotDemo/ready を待ってから撮る）
    private static var readyMarker: URL {
        folder.appendingPathComponent("ready")
    }

    /// 撮る場面を開く：映画館に入る場面では、動画を用意してから映画館に入り、ライブラリを閉じて、動画を開いて決まった位置で止める。
    /// 整ったら印のファイルを置く（動画を書き出しているあいだのライブラリや、読み込み中の映画館を撮らないように）
    struct Director: ViewModifier {
        @Environment(AppModel.self) private var appModel
        @Environment(\.openImmersiveSpace) private var openImmersiveSpace
        @Environment(\.dismissWindow) private var dismissWindow

        func body(content: Content) -> some View {
            content.onAppear {
                // ライブラリを閉じると View の task は取り消されるので、View に結び付けない Task で進める
                Task { await start() }
            }
        }

        private func start() async {
            guard let scene = ScreenshotDemo.scene, appModel.immersiveSpaceState == .closed else {
                return
            }
            try? FileManager.default.removeItem(at: readyMarker)
            if scene.entersTheater {
                guard await enterTheater(showingMovie: scene.showsMovie) else {
                    return
                }
            }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: readyMarker.path, contents: Data())
        }

        /// 映画館に入り、動画を映す場面では決まった位置で止める。入れなかったら false
        private func enterTheater(showingMovie: Bool) async -> Bool {
            if showingMovie {
                do {
                    try await ScreenshotMovie.write(to: movieURL)
                } catch {
                    Diagnostics.log("撮影モード：動画を書き出せなかった \(error)")
                    return false
                }
            }
            appModel.immersiveSpaceState = .inTransition
            guard case .opened = await openImmersiveSpace(id: appModel.immersiveSpaceID) else {
                appModel.immersiveSpaceState = .closed
                return false
            }
            dismissWindow(id: appModel.libraryWindowID)
            // 映画館のモデルを読み終える（TheaterView が舞台を作る）まで待つ
            guard await wait(until: { appModel.activeStage != nil }) else {
                return false
            }
            guard showingMovie else {
                return true
            }
            await appModel.player.open(url: movieURL)
            appModel.perform(.pause)
            appModel.perform(.seek(to: ScreenshotMovie.position))
            // 照明のページに出るので、上映の演出は既定（入）に戻しておく
            appModel.preferences.showtime = true
            // 止めた位置まで移る（時刻の表示が変わり終える）まで待つ
            return await wait {
                appModel.player.state == .paused && abs(appModel.player.currentTime - ScreenshotMovie.position) < 1
            }
        }

        /// condition が成り立つまで待つ（最大 60 秒）。成り立ったら true
        private func wait(until condition: () -> Bool) async -> Bool {
            for _ in 0..<600 {
                if condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            Diagnostics.log("撮影モード：場面が整わなかった")
            return false
        }
    }
}
#endif
