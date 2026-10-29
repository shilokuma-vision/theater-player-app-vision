//
//  Preferences.swift
//  TheaterPlayer
//
//  利用者の設定（部屋の明るさ・上映の演出・座る席・音量・音響・部屋の響き・操作パネルの位置）。UserDefaults に保存する。
//

import CinemaAudio
import Foundation
import Observation

@Observable
final class Preferences {
    /// 客電の明るさ（開場・休憩のとき。0〜4。1 が照明を焼き付けたときの明るさで、1 を超えると開場らしく明るくする）
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
    /// 上映の演出（動画を頭から再生すると、開演のブザー・2 段の暗転・幕が開くのあとに始める）
    var showtime: Bool {
        didSet { save(showtime, for: .showtime) }
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
    /// 操作パネルの位置（映画館の中。nil なら既定の位置＝座ったときのひざの上）
    var panelPosition: SIMD3<Float>? {
        didSet { savePanelPosition() }
    }

    static let defaultSeat = "G-17"
    /// 開場（再生していないとき）の客電の既定。上映前でも暗く感じないよう、焼き付けたときより明るくする
    /// （壁・天井・幕が黒っぽいので、3 倍の光でも見た目は約 2.5 倍。RKPreview で確かめた）
    static let defaultHouseLevel = 3.0
    /// 客電の明るさの上限（これより上げると、スクリーン・照明器具が白く飛ぶ）
    static let maxHouseLevel = 4.0
    private let defaults: UserDefaults

    private enum Key: String {
        // room は以前 @AppStorage("room") で保存していた。同じキーを読む
        case houseLevel, showLevel, autoDim, showtime, screenSpill, ambientLevel, seatID, volume, audio, room, panelPosition
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        houseLevel = defaults.object(forKey: Key.houseLevel.rawValue) as? Double ?? Self.defaultHouseLevel
        showLevel = defaults.object(forKey: Key.showLevel.rawValue) as? Double ?? 0
        autoDim = defaults.object(forKey: Key.autoDim.rawValue) as? Bool ?? true
        showtime = defaults.object(forKey: Key.showtime.rawValue) as? Bool ?? true
        screenSpill = defaults.object(forKey: Key.screenSpill.rawValue) as? Double ?? 1
        ambientLevel = defaults.object(forKey: Key.ambientLevel.rawValue) as? Double ?? 1
        seatID = defaults.string(forKey: Key.seatID.rawValue) ?? Self.defaultSeat
        volume = defaults.object(forKey: Key.volume.rawValue) as? Double ?? 1
        room = defaults.string(forKey: Key.room.rawValue).flatMap { SpatialSpeakers.Room(rawValue: $0) } ?? .standard
        if let values = defaults.array(forKey: Key.panelPosition.rawValue) as? [Double], values.count == 3 {
            panelPosition = SIMD3(Float(values[0]), Float(values[1]), Float(values[2]))
        } else {
            panelPosition = nil
        }
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

    private func savePanelPosition() {
        if let panelPosition {
            defaults.set([panelPosition.x, panelPosition.y, panelPosition.z].map(Double.init), forKey: Key.panelPosition.rawValue)
        } else {
            defaults.removeObject(forKey: Key.panelPosition.rawValue)
        }
    }

    private func saveAudio() {
        if let data = try? JSONEncoder().encode(audio) {
            defaults.set(data, forKey: Key.audio.rawValue)
        }
    }
}
