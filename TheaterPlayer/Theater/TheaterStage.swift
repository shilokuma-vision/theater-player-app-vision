//
//  TheaterStage.swift
//  TheaterPlayer
//
//  映画館の空間（RealityKit）。映画館のモデルと、スクリーンの映像・空間オーディオのスピーカー・照明の演出・席の移動をまとめる。
//

import Foundation
import Observation
import RealityKit
import TheaterMedia
import TheaterScene

@MainActor
@Observable
final class TheaterStage {
    let environment: TheaterEnvironment
    /// スクリーンに映像を貼るエンティティ（映像を出すあいだだけ有効）
    private(set) var videoScreen: ModelEntity?
    private(set) var screenFrame: ScreenFrame
    private let speakers = SpatialSpeakers()
    let lighting: LightingDirector
    @ObservationIgnored private var currentFormat: VideoFormat?
    /// 字幕・音楽の表示を置く、スクリーンの中心の手前の点（表示は、さらに曲面の出っ張りの分だけ手前に置く。overlayDepth）
    let screenAnchor = Entity()

    static func load(preferences: Preferences) async throws -> TheaterStage {
        let environment = try await TheaterEnvironment.load(bundle: .main)
        return TheaterStage(environment: environment, preferences: preferences)
    }

    private init(environment: TheaterEnvironment, preferences: Preferences) {
        self.environment = environment
        lighting = LightingDirector(initialHouse: preferences.houseLevel)
        screenFrame = ScreenFrame(aspect: 2.0, spec: environment.layout.screen)
        let screen = environment.layout.screen
        screenAnchor.name = "ScreenAnchor"
        screenAnchor.position = SIMD3(screen.center.x, screen.center.y, screen.center.z + 0.08)
        environment.model.addChild(screenAnchor)
        let seat = environment.layout.seat(id: preferences.seatID) ?? environment.layout.seat(id: Preferences.defaultSeat)
        if let seat {
            environment.sit(at: seat)
        }
        environment.root.components.set(ReverbComponent(reverb: SpatialSpeakers.Room.standard.reverb))
    }

    var root: Entity {
        environment.root
    }

    var layout: TheaterLayout {
        environment.layout
    }

    var currentSeat: Seat? {
        environment.currentSeat
    }

    // MARK: - 再生とつなぐ

    /// 再生のエンジンの映像・音声を、スクリーンとスピーカーにつなぐ
    func attach(_ engine: MediaPlayer) {
        let material = VideoMaterial(videoRenderer: engine.videoRenderer)
        if let mesh = try? ScreenMesh.make(frame: screenFrame, spec: layout.screen) {
            let screen = ModelEntity(mesh: mesh, materials: [material])
            screen.name = "VideoScreen"
            screen.isEnabled = false
            environment.model.addChild(screen)
            videoScreen = screen
        }
        speakers.build(layout: layout, ring: engine.ring, parent: environment.model)
        speakers.play()
    }

    func detach() {
        speakers.stop()
    }

    func setRoom(_ room: SpatialSpeakers.Room) {
        root.components.set(ReverbComponent(reverb: room.reverb))
    }

    /// 映像の形式に合わせて、スクリーンの映像の範囲とマスキングを変える。映像が無ければ（音楽）映像を消す
    func update(format: VideoFormat?, hasVideo: Bool) {
        videoScreen?.isEnabled = hasVideo && format != nil
        guard let format, format != currentFormat else {
            return
        }
        currentFormat = format
        let frame = ScreenFrame(aspect: Float(format.visibleAspect), spec: layout.screen)
        screenFrame = frame
        let rotation = VideoRotation(rawValue: format.rotation) ?? .none
        if let mesh = try? ScreenMesh.make(frame: frame, spec: layout.screen, rotation: rotation) {
            videoScreen?.model?.mesh = mesh
        }
        environment.setMasking(frame: frame)
    }

    /// 映像が無いとき（開いていない・音楽）のマスキング：最大の範囲
    func resetMasking() {
        currentFormat = nil
        let frame = ScreenFrame(aspect: 2.0, spec: layout.screen)
        // RealityView の update から何度も呼ばれるので、変わったときだけ書き換える（見ている View を作り直させない）
        if screenFrame != frame {
            screenFrame = frame
        }
        environment.setMasking(frame: frame)
    }

    /// 幅 width の平らな表示（字幕など）を、screenAnchor からどれだけ手前に置くか。
    /// スクリーンは端ほど客席側へ出ているので、表示の端の出っ張りより手前に置く（中心の手前だけだと、端がスクリーンに隠れる）
    func overlayDepth(width: Float) -> Float {
        ScreenMesh.sag(x: width / 2, spec: layout.screen)
    }

    // MARK: - 席

    /// 席を移る（暗転して移り、明るく戻す）
    func move(to seat: Seat) async {
        await lighting.blackout { [environment] in
            environment.sit(at: seat)
        }
    }

    // MARK: - 毎フレーム

    func update(deltaTime: Double, player: PlayerModel, preferences: Preferences) {
        let hasVideo = player.info.map { !$0.isAudioOnly } ?? false
        let values = lighting.step(
            deltaTime: deltaTime,
            playing: player.isPlaying,
            hasVideo: hasVideo,
            preferences: preferences,
            light: player.engine?.screenLight()
        )
        environment.lighting.update(values)
    }
}
