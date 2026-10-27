//
//  Preferences.swift
//  TheaterPlayer
//
//  利用者の設定（部屋の明るさ・座る席・音量・音響・部屋の響き）。UserDefaults に保存する。
//

import CinemaAudio
import Foundation
import Observation

@Observable
final class Preferences {
    /// 客電の明るさ（開場・休憩のとき。0〜1）
    var houseLevel: Double {
        didSet { save(houseLevel, for: .houseLevel) }
    }
    /// 上映中の客電の明るさ（0〜1。映画館では 0）
    var showLevel: Double {
        didSet { save(showLevel, for: .showLevel) }
    }
    /// 再生を始めたら客電を落とし、終わったら戻す
    var autoDim: Bool {
        didSet { save(autoDim, for: .autoDim) }
    }
    /// スクリーンの光の照り返しの強さ（0〜2）
    var screenSpill: Double {
        didSet { save(screenSpill, for: .screenSpill) }
    }
    /// 足元灯・誘導灯の明るさ（0〜1.5）
    var ambientLevel: Double {
        didSet { save(ambientLevel, for: .ambientLevel) }
    }
    /// 座る席（G-17 など）
    var seatID: String {
        didSet { save(seatID, for: .seatID) }
    }
    /// 音量（0〜1.5）
    var volume: Double {
        didSet { save(volume, for: .volume) }
    }
    /// 音響の設定
    var audio: CinemaAudioSettings {
        didSet { saveAudio() }
    }
    /// 部屋の響き（映画館に入ったときから効かせる）
    var room: SpatialSpeakers.Room {
        didSet { save(room.rawValue, for: .room) }
    }

    static let defaultSeat = "G-17"
    private let defaults: UserDefaults

    private enum Key: String {
        // room は以前 @AppStorage("room") で保存していた。同じキーを読む
        case houseLevel, showLevel, autoDim, screenSpill, ambientLevel, seatID, volume, audio, room
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        houseLevel = defaults.object(forKey: Key.houseLevel.rawValue) as? Double ?? 0.8
        showLevel = defaults.object(forKey: Key.showLevel.rawValue) as? Double ?? 0
        autoDim = defaults.object(forKey: Key.autoDim.rawValue) as? Bool ?? true
        screenSpill = defaults.object(forKey: Key.screenSpill.rawValue) as? Double ?? 1
        ambientLevel = defaults.object(forKey: Key.ambientLevel.rawValue) as? Double ?? 1
        seatID = defaults.string(forKey: Key.seatID.rawValue) ?? Self.defaultSeat
        volume = defaults.object(forKey: Key.volume.rawValue) as? Double ?? 1
        room = defaults.string(forKey: Key.room.rawValue).flatMap { SpatialSpeakers.Room(rawValue: $0) } ?? .standard
        if let data = defaults.data(forKey: Key.audio.rawValue),
           let decoded = try? JSONDecoder().decode(CinemaAudioSettings.self, from: data) {
            audio = decoded
        } else {
            audio = CinemaAudioSettings()
        }
    }

    private func save(_ value: Any, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    private func saveAudio() {
        if let data = try? JSONEncoder().encode(audio) {
            defaults.set(data, forKey: Key.audio.rawValue)
        }
    }
}
