//
//  PlayerModel.swift
//  TheaterPlayer
//
//  画面から使う再生の状態（MainActor）。TheaterMedia の MediaPlayer を包み、時刻・トラック・字幕を View に見せる。
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
    /// 映画館の空間オーディオの音源の系統（TheaterLayout.json のスピーカーの順）
    let speakers: [CinemaBus]
    /// 再生のエンジン（作れなければ nil。Metal・音声の準備に失敗したとき）
    let engine: MediaPlayer?
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

    var hasMedia: Bool {
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
        await start(url: url, title: url.deletingPathExtension().lastPathComponent, item: item)
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
            engine.play()
            startRefreshing()
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
        videoFormat = nil
        subtitles = []
        externalSubtitle = nil
        currentItem = nil
        currentTime = 0
    }

    // MARK: - 操作

    func togglePlay() {
        guard let engine else {
            return
        }
        if isPlaying {
            engine.pause()
            saveProgress()
        } else {
            engine.play()
        }
    }

    func seek(to time: Double) {
        engine?.seek(to: time)
        currentTime = time
    }

    func skip(by seconds: Double) {
        seek(to: max(0, min(currentTime + seconds, duration)))
    }

    var rate: Float {
        get { engine?.rate ?? 1 }
        set { engine?.rate = newValue }
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

    private func saveProgress(position: Double? = nil) {
        guard let item = currentItem, let info else {
            return
        }
        recents.update(item.id, position: position ?? currentTime, duration: info.duration, isAudioOnly: info.isAudioOnly)
    }
}
