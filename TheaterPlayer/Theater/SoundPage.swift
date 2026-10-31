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

    var body: some View {
        @Bindable var preferences = appModel.preferences
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Sound", page: $page)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Stereo Sound", selection: $preferences.audio.upmix) {
                        Text("Spread Like a Theater").tag(CinemaAudioSettings.Upmix.cinema)
                        Text("As Is").tag(CinemaAudioSettings.Upmix.off)
                    }
                    .pickerStyle(.segmented)
                    bassSection(preferences)
                    spaceSection(preferences)
                    Picker("Dynamic Range", selection: $preferences.audio.dynamicRange) {
                        Text("Theater").tag(CinemaAudioSettings.DynamicRange.cinema)
                        Text("Standard").tag(CinemaAudioSettings.DynamicRange.standard)
                        Text("Night").tag(CinemaAudioSettings.DynamicRange.night)
                    }
                    .pickerStyle(.segmented)
                    Picker("Room Reverb", selection: $preferences.room) {
                        Text("Subtle").tag(SpatialSpeakers.Room.dry)
                        Text("Standard").tag(SpatialSpeakers.Room.standard)
                        Text("Rich").tag(SpatialSpeakers.Room.rich)
                    }
                    .pickerStyle(.segmented)
                    Button("Reset to Defaults") {
                        preferences.audio = CinemaAudioSettings()
                    }
                }
            }
            .frame(maxHeight: 460)
        }
        .onChange(of: preferences.audio) { appModel.player.applyAudioPreferences() }
        // 映画館に入ったときの響きは TheaterStage が設定から付ける。ここでは変えたときだけ
        .onChange(of: preferences.room) {
            stage?.setRoom(preferences.room)
        }
    }

    private func bassSection(_ preferences: Preferences) -> some View {
        @Bindable var preferences = preferences
        return VStack(alignment: .leading, spacing: 10) {
            Text("Bass").font(.headline)
            LabeledSlider(
                title: "Bass Boost",
                value: Binding(
                    get: { Double(preferences.audio.bassBoostDB) },
                    set: { preferences.audio.bassBoostDB = Float($0) }
                ),
                range: 0...18,
                format: { String(format: "+%.0f dB", $0) }
            )
            LabeledSlider(
                title: "Bass Reverb (Large Room)",
                value: Binding(
                    get: { Double(preferences.audio.rumble) },
                    set: { preferences.audio.rumble = Float($0) }
                ),
                range: 0...1
            )
            LabeledSlider(
                title: "Virtual Bass (Harmonics You Can Feel)",
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
            Text("Surround").font(.headline)
            LabeledSlider(
                title: "Dialogue to Center",
                value: Binding(
                    get: { Double(preferences.audio.centerAmount) },
                    set: { preferences.audio.centerAmount = Float($0) }
                ),
                range: 0...1
            )
            LabeledSlider(
                title: "Ambience to Surrounds",
                value: Binding(
                    get: { Double(preferences.audio.ambienceAmount) },
                    set: { preferences.audio.ambienceAmount = Float($0) }
                ),
                range: 0...1
            )
            LabeledSlider(
                title: "Ceiling Speakers",
                value: Binding(
                    get: { Double(preferences.audio.heightAmount) },
                    set: { preferences.audio.heightAmount = Float($0) }
                ),
                range: 0...0.5
            )
            LabeledSlider(
                title: "Dialogue Boost",
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
