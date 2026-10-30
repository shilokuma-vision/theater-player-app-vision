//
//  PlayerModel.swift
//  TheaterPlayer
//
//  画面から使う再生の状態（MainActor）。TheaterMedia の MediaPlayer を包み、時刻・トラック・字幕を View に見せる。
//  画像・PDF（静止画）は MediaPlayer を使わずに開き、スクリーンに貼る 1 枚（still）を持つ。
//  動画を開いて頭から再生するときは、上映の進行（show）の開演の流れのあとに再生を始める。
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
    /// 3D の選び方（操作パネルの「3D」。ファイルを開くたびに「自動」に戻す）
    var stereoMode: StereoMode = .auto {
        didSet {
            engine?.stereoMode = stereoMode
            stereoPacking = engine?.stereo ?? .mono
        }
    }
    /// 今のファイルを映す左右の目の並べ方（スクリーンの縦横比を片目の絵に合わせる）
    private(set) var stereoPacking: StereoPacking = .mono
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
    /// 上映の進行（開演の流れ・エンドロール）
    let show = ShowDirector()
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

    /// 再生している（開演の流れを流しているあいだも。そのあいだに止めると、本編を始めずに止める）
    var isPlaying: Bool {
        state == .playing || state == .buffering || show.ceremony != nil
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
        if stereoMode != .auto {
            stereoMode = .auto
        }
        do {
            let opened = try await engine.open(url)
            stereoPacking = engine.stereo
            info = opened
            self.title = opened.title ?? title
            currentItem = item
            show.prepare(duration: opened.duration, chapters: opened.chapters, isVideo: !opened.isAudioOnly)
            selectedAudioTrack = engine.selectedAudioTrack
            selectedSubtitleTrack = engine.selectedSubtitleTrack
            Diagnostics.log("ファイルを開いた resume=\(item?.resumePosition.map { String($0) } ?? "なし")")
            if let resume = item?.resumePosition {
                engine.seek(to: resume)
                engine.play()
            } else if preferences.showtime, ShowDirector.wantsCeremony(isAudioOnly: opened.isAudioOnly, duration: opened.duration) {
                // 頭から再生する動画は、開演の流れ（ブザー → 客電を半分 → 幕が開く）のあとに始める
                show.begin { [weak self] in
                    self?.engine?.play()
                }
            } else {
                engine.play()
            }
            startRefreshing()
        } catch {
            errorMessage = error.localizedDescription
            info = nil
        }
    }

    /// 再生をやめる（位置を保存する）
    func close() {
        saveProgress()
        show.reset()
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
        stereoPacking = .mono
        still = nil
        stillDocument = nil
        pageRequest += 1
        videoFormat = nil
        subtitles = []
        externalSubtitle = nil
        currentItem = nil
        currentTime = 0
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

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            engine?.play()
        }
    }

    /// 止める（位置を保存する）。止まっていれば何もしない
    func pause() {
        guard isPlaying, let engine else {
            return
        }
        // 開演の流れのあいだに止めた：本編を始めずに止める（エンジンはまだ止まったまま）
        if show.ceremony != nil {
            show.cancel()
            return
        }
        engine.pause()
        saveProgress()
    }

    func seek(to time: Double) {
        engine?.seek(to: time)
        currentTime = time
        // 開演の流れのあいだにシークした：その位置からすぐに始める
        if show.ceremony != nil {
            startNow()
        }
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
    /// 音量：1 までは鳴らす直前で下げ、1 を超えた分は映画館の音響処理のリミッターの前で上げる（最大 4 倍＝ +12 dB。割れない）
    func applyAudioPreferences() {
        engine?.processor.update(settings: preferences.audio)
        let volume = Float(preferences.volume)
        engine?.ring.volume = min(volume, 1)
        engine?.processor.outputGain = max(volume, 1)
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
        // 本編のあいだ、エンドロールの始まりを探す（チャプターが無いとき、終わり近くの暗い画面で）
        if showPhase == .feature, let light = engine.screenLight() {
            show.observe(time: currentTime, light: light)
        }
    }

    private func saveProgress(position: Double? = nil) {
        guard let item = currentItem, let info else {
            return
        }
        recents.update(item.id, position: position ?? currentTime, duration: info.duration, isAudioOnly: info.isAudioOnly)
    }
}

// MARK: - 上映の進行

extension PlayerModel {
    /// 今の上映の段階（客電・幕を決める）
    var showPhase: ShowPhase {
        ShowPhase.resolve(
            ceremony: show.ceremony,
            state: state,
            showingStill: still != nil,
            inCredits: show.isCredits(at: currentTime),
            showtime: preferences.showtime && info.map { !$0.isAudioOnly } ?? false
        )
    }

    /// 開演の流れを省いて、すぐに本編を始める
    func startNow() {
        guard show.ceremony != nil else {
            return
        }
        show.cancel()
        engine?.play()
    }
}
