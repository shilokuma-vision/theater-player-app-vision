//
//  PlayerModel.swift
//  TheaterPlayer
//
//  画面から使う再生の状態（MainActor）。TheaterMedia の MediaPlayer を包み、時刻・トラック・字幕を View に見せる。
//  画像・PDF（静止画）は MediaPlayer を使わずに開き、スクリーンに貼る 1 枚（still）を持つ。
//

import CinemaAudio
import Foundation
import Observation
import TheaterMedia
import TheaterScene

@Observable
final class PlayerModel {
    private(set) var state: PlaybackState = .idle
    private(set) var info: MediaInfo?
    private(set) var title = ""
    private(set) var currentTime: Double = 0
    private(set) var videoFormat: VideoFormat?
    private(set) var subtitles: [SubtitleCue] = []
    private(set) var selectedAudioTrack: Int?
    private(set) var selectedSubtitleTrack: Int?
    private(set) var externalSubtitle: SubtitleTrack?
    private(set) var errorMessage: String?
    private(set) var currentItem: RecentItems.Item?
    /// スクリーンに出している静止画（画像・PDF のページ）。動画・音楽を開いているあいだは nil
    private(set) var still: StillPicture?
    @ObservationIgnored private var stillDocument: StillDocument?
    /// ページを開く操作の番号（続けて押したとき、古いページの結果は捨てる）
    @ObservationIgnored private var pageRequest = 0
    /// 映画館の空間オーディオの音源の系統（TheaterLayout.json のスピーカーの順）
    let speakers: [CinemaBus]
    /// 再生のエンジン（作れなければ nil。Metal・音声の準備に失敗したとき）
    let engine: MediaPlayer?
    /// システムの「再生中」（コントロールセンター・AirPods・Siri からの操作と、題名・位置の表示）
    let nowPlaying = NowPlaying()
    private let preferences: Preferences
    private let recents: RecentItems
    private var accessedURL: URL?
    /// 写真から選んだ動画の一時的なコピー（閉じたら消す）
    private var temporaryFile: URL?
    private var refreshTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    init(preferences: Preferences, recents: RecentItems) {
        self.preferences = preferences
        self.recents = recents
        let layout = Bundle.main.url(forResource: "TheaterLayout", withExtension: "json").flatMap { try? TheaterLayout.load(from: $0) }
        speakers = layout?.emitters.compactMap { CinemaBus(rawValue: $0.bus) } ?? [.left, .center, .right, .lfe]
        engine = try? MediaPlayer(speakers: speakers)
        engine?.processor.update(settings: preferences.audio)
        engine?.ring.volume = Float(preferences.volume)
        listen()
    }

    var duration: Double {
        info?.duration ?? 0
    }

    var isPlaying: Bool {
        state == .playing || state == .buffering
    }

    /// 何か開いている（動画・音楽・画像・PDF）
    var hasMedia: Bool {
        info != nil || still != nil
    }

    /// 再生できる物（動画・音楽）を開いている。再生の操作・音声・字幕・速さは、このときだけ
    var hasPlayback: Bool {
        info != nil
    }

    // MARK: - 開く

    /// ファイルを開いて再生する（最近の一覧に入れ、前回の続きから）。
    /// temporary：写真から選んだ動画の一時的なコピー。あとで開き直せないので一覧には入れず、閉じたら消す
    func open(url: URL, temporary: Bool = false) async {
        await open(url: url, recentID: nil, temporary: temporary)
    }

    /// 最近の一覧から開く（その項目を書き換える）
    func open(_ item: RecentItems.Item) async {
        guard let url = recents.resolve(item) else {
            errorMessage = String(localized: "ファイルが見つかりません。もう一度選んでください。")
            return
        }
        await open(url: url, recentID: item.id, temporary: false)
    }

    private func open(url: URL, recentID: UUID?, temporary: Bool) async {
        close()
        let accessing = url.startAccessingSecurityScopedResource()
        accessedURL = accessing ? url : nil
        temporaryFile = temporary ? url : nil
        let item = temporary ? nil : recents.add(url: url, replacing: recentID)
        let title = url.deletingPathExtension().lastPathComponent
        if StillDocument.kind(of: url) != nil {
            await showStill(url: url, title: title, item: item)
        } else {
            await start(url: url, title: title, item: item)
        }
    }

    private func start(url: URL, title: String, item: RecentItems.Item?) async {
        guard let engine else {
            errorMessage = String(localized: "再生の準備ができませんでした。")
            return
        }
        errorMessage = nil
        do {
            let opened = try await engine.open(url)
            info = opened
            self.title = opened.title ?? title
            currentItem = item
            selectedAudioTrack = engine.selectedAudioTrack
            selectedSubtitleTrack = engine.selectedSubtitleTrack
            if let resume = item?.resumePosition {
                engine.seek(to: resume)
            }
            nowPlaying.activate()
            engine.play()
            startRefreshing()
            publishNowPlaying()
        } catch {
            errorMessage = error.localizedDescription
            info = nil
        }
    }

    /// 再生をやめる（位置を保存する）
    func close() {
        saveProgress()
        refreshTask?.cancel()
        refreshTask = nil
        engine?.close()
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        if let temporaryFile {
            try? FileManager.default.removeItem(at: temporaryFile)
        }
        temporaryFile = nil
        info = nil
        still = nil
        stillDocument = nil
        pageRequest += 1
        videoFormat = nil
        subtitles = []
        externalSubtitle = nil
        currentItem = nil
        currentTime = 0
        publishNowPlaying()
    }

    // MARK: - 静止画（画像・PDF）

    /// 画像・PDF を開いてスクリーンに出す（PDF は前回見ていたページから）
    private func showStill(url: URL, title: String, item: RecentItems.Item?) async {
        errorMessage = nil
        do {
            let document = try await Task.detached(priority: .userInitiated) { try StillDocument.open(url) }.value
            stillDocument = document
            self.title = title
            currentItem = item
            await showPage(min(max(item?.page ?? 0, 0), document.pageCount - 1))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// PDF の index ページ目（0 から）を出す
    func showPage(_ index: Int) async {
        guard let document = stillDocument, (0..<document.pageCount).contains(index) else {
            return
        }
        pageRequest += 1
        let request = pageRequest
        do {
            let picture = try await Task.detached(priority: .userInitiated) { try document.render(page: index) }.value
            // 待っているあいだに、別のページ・別のファイルを開いた
            guard request == pageRequest else {
                return
            }
            still = picture
            if let item = currentItem {
                recents.updateStill(item.id, kind: document.kind, page: index)
            }
        } catch {
            guard request == pageRequest else {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func nextPage() async {
        if let still {
            await showPage(still.page + 1)
        }
    }

    func previousPage() async {
        if let still {
            await showPage(still.page - 1)
        }
    }

    // MARK: - 操作

    /// 再生の操作を行う（AppModel.perform(_:) から呼ぶ。パネルを出す操作は AppModel が受ける）。動画・音楽を開いていなければ何もしない
    func perform(_ command: PlayerCommand) {
        guard hasPlayback, let engine else {
            return
        }
        switch command {
        case .togglePlay:
            if isPlaying {
                pause(engine)
            } else {
                engine.play()
            }
        case .play:
            engine.play()
        case .pause:
            pause(engine)
        case .skip, .seek, .nextChapter, .previousChapter:
            if let target = command.seekTarget(from: currentTime, duration: duration, chapterStarts: info?.chapters.map(\.start) ?? []) {
                engine.seek(to: target)
                currentTime = target
                publishNowPlaying()
            }
        case let .setRate(newRate):
            engine.rate = newRate
            publishNowPlaying()
        case .showPanel:
            break
        }
    }

    private func pause(_ engine: MediaPlayer) {
        engine.pause()
        saveProgress()
    }

    var rate: Float {
        engine?.rate ?? 1
    }

    var audioDelay: Double {
        get { engine?.audioDelay ?? 0 }
        set { engine?.audioDelay = newValue }
    }

    var subtitleDelay: Double {
        get { engine?.subtitleDelay ?? 0 }
        set { engine?.subtitleDelay = newValue }
    }

    func selectAudioTrack(_ id: Int) {
        try? engine?.selectAudioTrack(id)
        selectedAudioTrack = id
    }

    func selectSubtitleTrack(_ id: Int?) {
        try? engine?.selectSubtitleTrack(id)
        selectedSubtitleTrack = id
        externalSubtitle = nil
    }

    func loadSubtitles(from url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            externalSubtitle = try await engine?.loadExternalSubtitles(url)
            selectedSubtitleTrack = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 音響の設定・音量を反映する
    func applyAudioPreferences() {
        engine?.processor.update(settings: preferences.audio)
        engine?.ring.volume = Float(preferences.volume)
    }

    // MARK: - 状態の更新

    private func listen() {
        guard let engine else {
            return
        }
        eventTask = Task { [weak self] in
            for await event in engine.events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: MediaPlayerEvent) {
        switch event {
        case let .state(newState):
            state = newState
            if newState == .ended {
                saveProgress(position: 0)
            }
            publishNowPlaying()
        case let .videoFormat(format):
            videoFormat = format
        case let .error(message):
            errorMessage = message
        }
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.refresh()
                ticks += 1
                if ticks.isMultiple(of: 50) {
                    self?.saveProgress()
                }
            }
        }
    }

    private func refresh() {
        guard let engine else {
            return
        }
        currentTime = engine.currentTime
        subtitles = engine.subtitles(at: engine.displayTime)
    }

    /// システムの Now Playing に、今の再生の様子を見せる（動画・音楽を開いていなければ消す）。
    /// 位置はシステムが速さから進めるので、変わり目（開いた・再生／一時停止・シーク・速さ）にだけ呼ぶ
    private func publishNowPlaying() {
        guard let info, let engine else {
            nowPlaying.update(nil, artwork: nil)
            return
        }
        let item = NowPlaying.Item(
            title: title,
            artist: info.artist,
            album: info.album,
            duration: info.duration ?? 0,
            elapsed: engine.currentTime,
            rate: state == .playing ? Double(engine.rate) : 0,
            isAudioOnly: info.isAudioOnly,
            chapterCount: info.chapters.count
        )
        nowPlaying.update(item, artwork: info.artwork)
    }

    private func saveProgress(position: Double? = nil) {
        guard let item = currentItem, let info else {
            return
        }
        recents.update(item.id, position: position ?? currentTime, duration: info.duration, isAudioOnly: info.isAudioOnly)
    }
}
