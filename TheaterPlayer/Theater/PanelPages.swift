//
//  PanelPages.swift
//  TheaterPlayer
//
//  操作パネルのページ：音声のトラック・字幕・再生の速さ・部屋の明るさ。
//

import SwiftUI
import TheaterMedia

/// ページの見出し（戻るボタン付き）
struct PageHeader: View {
    let title: LocalizedStringKey
    @Binding var page: ControlPanel.Page

    var body: some View {
        HStack {
            Button {
                page = .main
            } label: {
                Label("戻る", systemImage: "chevron.left")
            }
            Spacer()
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            Color.clear.frame(width: 80, height: 1)
        }
    }
}

/// 選ぶ行（選んでいる物に印）
struct ChoiceRow: View {
    let title: String
    let detail: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading) {
                    Text(title)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

struct AudioTrackPage: View {
    @Binding var page: ControlPanel.Page
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let player = appModel.player
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title: "音声", page: $page)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(player.info?.audioTracks ?? []) { track in
                        ChoiceRow(
                            title: Self.name(track),
                            detail: "\(track.codec.uppercased())・\(track.layoutName)・\(track.sampleRate / 1_000) kHz",
                            selected: player.selectedAudioTrack == track.id
                        ) {
                            player.selectAudioTrack(track.id)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            DelayStepper(title: "音のずれ", value: Binding(get: { player.audioDelay }, set: { player.audioDelay = $0 }))
        }
    }

    static func name(_ track: AudioTrack) -> String {
        [track.title, track.language.map(LanguageName.display)].compactMap { $0 }.joined(separator: "・").nonEmpty
            ?? String(localized: "トラック \(track.id)")
    }
}

struct SubtitlePage: View {
    @Binding var page: ControlPanel.Page
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let player = appModel.player
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title: "字幕", page: $page)
            ScrollView {
                VStack(alignment: .leading) {
                    ChoiceRow(
                        title: String(localized: "字幕なし"),
                        detail: nil,
                        selected: player.selectedSubtitleTrack == nil && player.externalSubtitle == nil
                    ) {
                        player.selectSubtitleTrack(nil)
                    }
                    ForEach(player.info?.subtitleTracks ?? []) { track in
                        ChoiceRow(
                            title: Self.name(track),
                            detail: track.codec.uppercased(),
                            selected: player.selectedSubtitleTrack == track.id
                        ) {
                            player.selectSubtitleTrack(track.id)
                        }
                    }
                    if let external = player.externalSubtitle {
                        ChoiceRow(title: external.title ?? "", detail: String(localized: "ファイルから読んだ字幕"), selected: true) {}
                    }
                }
            }
            .frame(maxHeight: 300)
            Button {
                openWindow(id: appModel.libraryWindowID)
                appModel.requestSubtitleFile = true
            } label: {
                Label("字幕ファイルを選ぶ（ライブラリ）", systemImage: "doc.badge.plus")
            }
            DelayStepper(title: "字幕のずれ", value: Binding(get: { player.subtitleDelay }, set: { player.subtitleDelay = $0 }))
        }
    }

    static func name(_ track: SubtitleTrack) -> String {
        var parts = [track.title, track.language.map(LanguageName.display)].compactMap { $0 }
        if track.isForced {
            parts.append(String(localized: "強制"))
        }
        return parts.joined(separator: "・").nonEmpty ?? String(localized: "字幕 \(track.id)")
    }
}

/// 音・字幕のずれを 0.05 秒ずつ合わせる
struct DelayStepper: View {
    let title: LocalizedStringKey
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button { value -= 0.05 } label: { Image(systemName: "minus") }
            Text(String(format: "%+.2f 秒", value)).monospacedDigit().frame(width: 100)
            Button { value += 0.05 } label: { Image(systemName: "plus") }
            Button("0") { value = 0 }
        }
    }
}

struct SpeedPage: View {
    @Binding var page: ControlPanel.Page
    @Environment(AppModel.self) private var appModel
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        let player = appModel.player
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title: "再生の速さ", page: $page)
            ForEach(Self.speeds, id: \.self) { speed in
                ChoiceRow(
                    title: String(format: "%.2g 倍", speed),
                    detail: speed == 1 ? String(localized: "ふつう") : nil,
                    selected: abs(player.rate - speed) < 0.01
                ) {
                    appModel.perform(.setRate(speed))
                }
            }
        }
    }
}

/// 3D（立体視）：左右の目の絵の並べ方を選ぶ。「自動」は入れ物の立体の情報・ファイル名から決める
struct StereoPage: View {
    @Binding var page: ControlPanel.Page
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let player = appModel.player
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title: "3D", page: $page)
            ChoiceRow(
                title: String(localized: "自動"),
                detail: String(localized: "このファイル：\(Self.name(of: player.stereoPacking))"),
                selected: player.stereoMode == .auto
            ) {
                player.stereoMode = .auto
            }
            ChoiceRow(title: String(localized: "2D（立体にしない）"), detail: nil, selected: player.stereoMode == .off) {
                player.stereoMode = .off
            }
            ChoiceRow(
                title: String(localized: "左右に並べた 3D"),
                detail: String(localized: "サイドバイサイド（SBS・HSBS）"),
                selected: player.stereoMode == .sideBySide
            ) {
                player.stereoMode = .sideBySide
            }
            ChoiceRow(
                title: String(localized: "上下に並べた 3D"),
                detail: String(localized: "トップアンドボトム（TAB・OU）"),
                selected: player.stereoMode == .overUnder
            ) {
                player.stereoMode = .overUnder
            }
        }
    }

    static func name(of packing: StereoPacking) -> String {
        switch packing {
        case .mono:
            String(localized: "2D")
        case .sideBySide:
            String(localized: "左右に並べた 3D")
        case .overUnder:
            String(localized: "上下に並べた 3D")
        case .multiview:
            String(localized: "空間ビデオ（3D）")
        }
    }
}

struct LightingPage: View {
    @Binding var page: ControlPanel.Page
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var preferences = appModel.preferences
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "部屋の明るさ", page: $page)
            // 開場（止めているとき）の明るさと、上映中の明るさの組み合わせ
            HStack {
                presetButton("明るい", house: Preferences.maxHouseLevel, show: 0.25)
                presetButton("映画館", house: Preferences.defaultHouseLevel, show: 0)
                presetButton("ほの暗い", house: 0.45, show: 0.08)
                presetButton("真っ暗", house: 0, show: 0)
            }
            LabeledSlider(title: "客電（止めているとき）", value: $preferences.houseLevel, range: 0...Preferences.maxHouseLevel)
            LabeledSlider(title: "客電（上映中）", value: $preferences.showLevel, range: 0...1)
            LabeledSlider(title: "足元灯・誘導灯", value: $preferences.ambientLevel, range: 0...1.5)
            LabeledSlider(title: "スクリーンの照り返し", value: $preferences.screenSpill, range: 0...2)
            Toggle("再生すると暗くする", isOn: $preferences.autoDim)
        }
    }

    private func presetButton(_ title: LocalizedStringKey, house: Double, show: Double) -> some View {
        Button {
            appModel.preferences.houseLevel = house
            appModel.preferences.showLevel = show
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

/// 名前と値つきのスライダー
struct LabeledSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

/// 言語のコード（jpn・eng など）を、表示の名前にする
enum LanguageName {
    static func display(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

extension String {
    /// 空なら nil
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
