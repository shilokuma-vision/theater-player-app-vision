//
//  SoundPage.swift
//  TheaterPlayer
//
//  操作パネルの「音響」：ステレオの広げ方・低音・音量の幅・部屋の響き。
//

import CinemaAudio
import SwiftUI

struct SoundPage: View {
    let stage: TheaterStage?
    @Binding var page: ControlPanel.Page
    @Environment(AppModel.self) private var appModel
    @AppStorage("room") private var room = SpatialSpeakers.Room.standard.rawValue

    var body: some View {
        @Bindable var preferences = appModel.preferences
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "音響", page: $page)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("ステレオの音", selection: $preferences.audio.upmix) {
                        Text("映画館のように広げる").tag(CinemaAudioSettings.Upmix.cinema)
                        Text("そのまま").tag(CinemaAudioSettings.Upmix.off)
                    }
                    .pickerStyle(.segmented)
                    bassSection(preferences)
                    spaceSection(preferences)
                    Picker("音量の幅", selection: $preferences.audio.dynamicRange) {
                        Text("映画館").tag(CinemaAudioSettings.DynamicRange.cinema)
                        Text("標準").tag(CinemaAudioSettings.DynamicRange.standard)
                        Text("夜").tag(CinemaAudioSettings.DynamicRange.night)
                    }
                    .pickerStyle(.segmented)
                    Picker("部屋の響き", selection: $room) {
                        Text("控えめ").tag(SpatialSpeakers.Room.dry.rawValue)
                        Text("標準").tag(SpatialSpeakers.Room.standard.rawValue)
                        Text("豊か").tag(SpatialSpeakers.Room.rich.rawValue)
                    }
                    .pickerStyle(.segmented)
                    Button("初期値に戻す") {
                        preferences.audio = CinemaAudioSettings()
                    }
                }
            }
            .frame(maxHeight: 460)
        }
        .onChange(of: preferences.audio) { appModel.player.applyAudioPreferences() }
        .onChange(of: room, initial: true) {
            stage?.setRoom(SpatialSpeakers.Room(rawValue: room) ?? .standard)
        }
    }

    private func bassSection(_ preferences: Preferences) -> some View {
        @Bindable var preferences = preferences
        return VStack(alignment: .leading, spacing: 10) {
            Text("低音").font(.headline)
            LabeledSlider(
                title: "低音の量",
                value: Binding(
                    get: { Double(preferences.audio.bassBoostDB) },
                    set: { preferences.audio.bassBoostDB = Float($0) }
                ),
                range: 0...12,
                format: { String(format: "+%.0f dB", $0) }
            )
            LabeledSlider(
                title: "低音の残響（大きな部屋の響き）",
                value: Binding(
                    get: { Double(preferences.audio.rumble) },
                    set: { preferences.audio.rumble = Float($0) }
                ),
                range: 0...1
            )
            LabeledSlider(
                title: "体感の低音（倍音で低音を感じやすく）",
                value: Binding(
                    get: { Double(preferences.audio.virtualBass) },
                    set: { preferences.audio.virtualBass = Float($0) }
                ),
                range: 0...1
            )
        }
    }

    private func spaceSection(_ preferences: Preferences) -> some View {
        @Bindable var preferences = preferences
        return VStack(alignment: .leading, spacing: 10) {
            Text("広がり").font(.headline)
            LabeledSlider(
                title: "台詞をセンターへ",
                value: Binding(
                    get: { Double(preferences.audio.centerAmount) },
                    set: { preferences.audio.centerAmount = Float($0) }
                ),
                range: 0...1
            )
            LabeledSlider(
                title: "響きをサラウンドへ",
                value: Binding(
                    get: { Double(preferences.audio.ambienceAmount) },
                    set: { preferences.audio.ambienceAmount = Float($0) }
                ),
                range: 0...1
            )
            LabeledSlider(
                title: "天井のスピーカー",
                value: Binding(
                    get: { Double(preferences.audio.heightAmount) },
                    set: { preferences.audio.heightAmount = Float($0) }
                ),
                range: 0...0.5
            )
            LabeledSlider(
                title: "台詞を聞きやすく",
                value: Binding(
                    get: { Double(preferences.audio.dialogueBoostDB) },
                    set: { preferences.audio.dialogueBoostDB = Float($0) }
                ),
                range: 0...9,
                format: { String(format: "+%.0f dB", $0) }
            )
        }
    }
}
