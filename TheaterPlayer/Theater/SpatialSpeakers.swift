//
//  SpatialSpeakers.swift
//  TheaterPlayer
//
//  映画館のスピーカーの位置に、空間オーディオの音源（RealityKit の生成器）を置く。
//  音源ごとに、映画館の音響処理を通したそのスピーカーの信号（SpeakerFeedRing）を鳴らす。
//  スクリーンの裏の L・C・R、サブウーファー、側壁・後方・天井のサラウンドで、映画館の音場を作る。
//

import AudioToolbox
import CinemaAudio
import RealityKit
import TheaterScene

@MainActor
final class SpatialSpeakers {
    private(set) var entities: [Entity] = []
    private var controllers: [AudioGeneratorController] = []

    /// 部屋の響き（ReverbComponent の種類）
    enum Room: String, CaseIterable, Identifiable {
        case dry, standard, rich

        var id: String { rawValue }

        var reverb: Reverb {
            switch self {
            case .dry:
                .preset(.mediumRoomTreated)
            case .standard:
                .preset(.largeRoomTreated)
            case .rich:
                .preset(.largeRoom)
            }
        }
    }

    /// layout のスピーカーの位置に音源を作り、parent（映画館のモデル）に付ける
    func build(layout: TheaterLayout, ring: SpeakerFeedRing, parent: Entity) {
        for (index, emitter) in layout.emitters.enumerated() {
            let entity = Entity()
            entity.name = "Speaker_\(emitter.id)"
            parent.addChild(entity)
            entity.look(at: emitter.position + emitter.forward, from: emitter.position, relativeTo: parent)
            entity.components.set(Self.spatialAudio(for: emitter.bus))
            do {
                let controller = try entity.prepareAudio(configuration: AudioGeneratorConfiguration(layoutTag: kAudioChannelLayoutTag_Mono),
                                                         ring.renderBlock(feed: index))
                controllers.append(controller)
            } catch {
                continue
            }
            entities.append(entity)
        }
    }

    func play() {
        for controller in controllers where !controller.isPlaying {
            controller.play()
        }
    }

    func stop() {
        controllers.forEach { $0.stop() }
    }

    /// スピーカーの種類ごとの鳴り方（向きの鋭さ・距離での減り方）
    static func spatialAudio(for bus: String) -> SpatialAudioComponent {
        switch bus {
        case "L", "C", "R":
            // スクリーンのスピーカー：客席へ向けた指向性。後ろの席まで届くよう距離で減りにくく
            SpatialAudioComponent(gain: 0, directivity: .beam(focus: 0.35), distanceAttenuation: .rolloff(factor: 0.45))
        case "LFE":
            // サブウーファー：向きは無く、部屋じゅうに回る
            SpatialAudioComponent(gain: 2, directivity: .beam(focus: 0), distanceAttenuation: .rolloff(factor: 0.2))
        default:
            // サラウンド：広く拡散
            SpatialAudioComponent(gain: 0, directivity: .beam(focus: 0.15), distanceAttenuation: .rolloff(factor: 0.6))
        }
    }
}
