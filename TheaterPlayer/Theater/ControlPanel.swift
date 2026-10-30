//
//  ControlPanel.swift
//  TheaterPlayer
//
//  手元の操作パネル（座席の前、ひざの上あたりに浮かぶ）。再生の操作と、照明・席・音響・トラックの切り替え。
//  映画館の中ではメニュー（ポップオーバー）を出せないので、パネルの中でページを切り替える。
//  再生中は 6 秒操作しないと小さく畳む（映画の邪魔をしない）。
//

import SwiftUI
import TheaterMedia

struct ControlPanel: View {
    enum Page: Hashable {
        case main, audioTracks, subtitles, speed, stereo, lighting, seats, sound
        #if DEBUG
        /// デバッグ用：YouTube の検索
        case youTube
        #endif
    }

    let stage: TheaterStage?
    let loadError: String?
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var page = Page.main
    @State private var collapsed = false
    @State private var lastInteraction = Date()

    var body: some View {
        Group {
            if collapsed {
                Button {
                    touch()
                } label: {
                    Label("操作を表示", systemImage: "chevron.up")
                }
                .padding(12)
                .glassBackgroundEffect()
            } else {
                expanded
                    .frame(width: 720)
                    .padding(28)
                    .glassBackgroundEffect()
            }
        }
        .task(id: lastInteraction) {
            // 操作し直すと前の待ちは取り消される。取り消されたら畳まない
            // （try? で続けると、「操作を表示」を押した瞬間にまた畳んでしまう）
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }
            // 再生中・静止画を出しているあいだは、畳んでスクリーンを見やすくする
            if appModel.player.isPlaying || appModel.player.still != nil, page == .main, !appModel.isMovingPanel {
                withAnimation { collapsed = true }
            }
        }
        // 下のつまみでパネルを動かし終えた・スクリーンをつまんで呼ばれたら、開いて、畳むまでの待ちをやり直す
        .onChange(of: appModel.panelInteraction) {
            touch()
        }
        // パネルの外（コントロールセンター・AirPods・Siri など）から再生を始めた・止めたときも、畳むまでの待ちをやり直す。
        // 止めているあいだに待ちが終わっていると、外から再生を始めたあと、パネルが開いたまま残る
        .onChange(of: appModel.player.isPlaying) {
            lastInteraction = Date()
        }
        .simultaneousGesture(TapGesture().onEnded { touch() })
    }

    private func touch() {
        lastInteraction = Date()
        withAnimation { collapsed = false }
    }

    @ViewBuilder private var expanded: some View {
        switch page {
        case .main:
            mainPage
        case .audioTracks:
            AudioTrackPage(page: $page)
        case .subtitles:
            SubtitlePage(page: $page)
        case .speed:
            SpeedPage(page: $page)
        case .stereo:
            StereoPage(page: $page)
        case .lighting:
            LightingPage(page: $page)
        case .seats:
            SeatPicker(stage: stage, page: $page)
        case .sound:
            SoundPage(stage: stage, page: $page)
        #if DEBUG
        case .youTube:
            YouTubePage(page: $page)
        #endif
        }
    }

    private var mainPage: some View {
        VStack(spacing: 18) {
            if let loadError {
                Text(loadError).foregroundStyle(.red)
            }
            NowPlayingHeader()
            if let still = appModel.player.still {
                StillControls(still: still)
            } else if appModel.player.hasPlayback {
                TransportControls()
            } else {
                Text("ライブラリでファイルを選ぶと、ここで再生します")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                // 音声・字幕・速さは、動画・音楽のときだけ（画像・PDF には無い）
                pageButton("音声", systemImage: "waveform", page: .audioTracks)
                    .disabled(!appModel.player.hasPlayback)
                pageButton("字幕", systemImage: "captions.bubble", page: .subtitles)
                    .disabled(!appModel.player.hasPlayback)
                pageButton("速さ", systemImage: "gauge.with.dots.needle.50percent", page: .speed)
                    .disabled(!appModel.player.hasPlayback)
                // 3D（立体視）は映像のときだけ
                pageButton("3D", systemImage: "view.3d", page: .stereo)
                    .disabled(appModel.player.info?.isAudioOnly ?? true)
                pageButton("明るさ", systemImage: "lightbulb.max", page: .lighting)
                pageButton("座席", systemImage: "chair", page: .seats)
                pageButton("音響", systemImage: "hifispeaker.2", page: .sound)
            }
            HStack {
                Button {
                    openWindow(id: appModel.libraryWindowID)
                } label: {
                    Label("ライブラリ", systemImage: "rectangle.stack")
                }
                #if DEBUG
                // デバッグ用の YouTube（上の段はボタンで埋まっているので、こちらに置く）
                Button {
                    page = .youTube
                    touch()
                } label: {
                    Label("YouTube", systemImage: "play.rectangle")
                }
                .accessibilityIdentifier("youTubePage")
                #endif
                Spacer()
                // 下のつまみで動かしたパネルを、座ったときのひざの上へ戻す
                if appModel.preferences.panelPosition != nil {
                    Button {
                        appModel.preferences.panelPosition = nil
                    } label: {
                        Label("パネルを元の位置へ", systemImage: "arrow.uturn.down")
                    }
                    Spacer()
                }
                Button(role: .destructive) {
                    leave()
                } label: {
                    Label("映画館を出る", systemImage: "door.left.hand.open")
                }
                .accessibilityIdentifier("leaveTheater")
            }
        }
    }

    /// 映画館を出る：ライブラリを開いてから、映画館を閉じる
    private func leave() {
        // 2 度押したときに、ライブラリを 2 つ開かない
        guard appModel.immersiveSpaceState != .inTransition else {
            return
        }
        // 閉じ終わる（TheaterView の onDisappear）までは .inTransition にしておく。
        // 開き直したライブラリで「映画館に入る」・再生を押しても、閉じ終わるのを待ってから開く
        appModel.immersiveSpaceState = .inTransition
        if !appModel.isLibraryOpen {
            openWindow(id: appModel.libraryWindowID)
        }
        Task {
            await dismissImmersiveSpace()
        }
    }

    private func pageButton(_ title: LocalizedStringKey, systemImage: String, page target: Page) -> some View {
        Button {
            page = target
            touch()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage).font(.title2)
                Text(title).font(.caption)
            }
            .frame(width: 88, height: 64)
        }
        .buttonStyle(.bordered)
    }
}

/// 曲名・題名と、時刻
struct NowPlayingHeader: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let player = appModel.player
        VStack(spacing: 4) {
            Text(player.hasMedia ? player.title : String(localized: "Theater Player"))
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            if let artist = player.info?.artist, player.info?.isAudioOnly == true {
                Text(artist).font(.subheadline).foregroundStyle(.secondary)
            }
            if let message = player.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

/// 静止画（画像・PDF）のとき：PDF のページの移動
struct StillControls: View {
    @Environment(AppModel.self) private var appModel
    let still: StillPicture

    var body: some View {
        let player = appModel.player
        if still.pageCount > 1 {
            HStack(spacing: 28) {
                Button {
                    Task { await player.previousPage() }
                } label: {
                    Image(systemName: "chevron.left").font(.title).frame(width: 64, height: 64)
                }
                .disabled(still.page == 0)
                .accessibilityLabel("前のページ")
                Text("\(still.page + 1) / \(still.pageCount) ページ")
                    .font(.title3)
                    .monospacedDigit()
                Button {
                    Task { await player.nextPage() }
                } label: {
                    Image(systemName: "chevron.right").font(.title).frame(width: 64, height: 64)
                }
                .disabled(still.page + 1 >= still.pageCount)
                .accessibilityLabel("次のページ")
            }
            .buttonStyle(.borderless)
        } else {
            Label(still.kind == .pdf ? "PDF" : "画像", systemImage: still.kind == .pdf ? "doc.richtext" : "photo")
                .foregroundStyle(.secondary)
        }
    }
}

/// シーク・再生・音量
struct TransportControls: View {
    @Environment(AppModel.self) private var appModel
    @State private var scrubbing: Double?

    var body: some View {
        let player = appModel.player
        VStack(spacing: 14) {
            Slider(
                value: Binding(get: { scrubbing ?? player.currentTime }, set: { scrubbing = $0 }),
                in: 0...max(player.duration, 1)
            ) { editing in
                if !editing, let target = scrubbing {
                    appModel.perform(.seek(to: target))
                    scrubbing = nil
                }
            }
            HStack {
                Text(TimeFormat.clock(scrubbing ?? player.currentTime)).monospacedDigit()
                Spacer()
                // 開演の流れ（ブザー・暗転・幕）のあいだは、省いてすぐに始められる
                if player.show.ceremony != nil {
                    Button {
                        player.startNow()
                    } label: {
                        Label("すぐに始める", systemImage: "forward.end.fill")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                Text("-" + TimeFormat.clock(max(0, player.duration - (scrubbing ?? player.currentTime)))).monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            HStack(spacing: 28) {
                Button { appModel.perform(.skip(by: -10)) } label: { Image(systemName: "gobackward.10").font(.title) }
                Button { appModel.perform(.togglePlay) } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.largeTitle)
                        .frame(width: 64, height: 64)
                }
                Button { appModel.perform(.skip(by: 30)) } label: { Image(systemName: "goforward.30").font(.title) }
            }
            .buttonStyle(.borderless)
            VolumeSlider()
        }
    }
}

struct VolumeSlider: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var preferences = appModel.preferences
        HStack {
            Image(systemName: "speaker.fill")
            Slider(value: $preferences.volume, in: 0...Preferences.maxVolume)
                .onChange(of: preferences.volume) { appModel.player.applyAudioPreferences() }
            Image(systemName: "speaker.wave.3.fill")
            // 等倍より上げたぶん（リミッターの前で上げる）
            Text(preferences.volume > 1 ? String(format: "+%.0f dB", 20 * log10(preferences.volume)) : "")
                .font(.caption.monospacedDigit())
                .frame(width: 52, alignment: .leading)
        }
        .foregroundStyle(.secondary)
    }
}

/// 時刻の表示（1:23:45）
enum TimeFormat {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else {
            return "--:--"
        }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = total / 60 % 60
        let rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
