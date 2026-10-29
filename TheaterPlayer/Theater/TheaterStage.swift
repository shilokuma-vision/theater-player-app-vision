//
//  TheaterStage.swift
//  TheaterPlayer
//
//  映画館の空間（RealityKit）。映画館のモデルと、スクリーンの映像・静止画（画像・PDF）・空間オーディオのスピーカー・
//  照明の演出・席の移動をまとめる。
//

@preconcurrency import AVFoundation
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
    /// 映像のスクリーンを見せているか（スクリーンは無効にせず、透明さで隠す）
    @ObservationIgnored private(set) var isShowingVideo = false
    /// つないでいる再生のエンジン（外すときに、コマを渡すのを止める）
    @ObservationIgnored private weak var engine: MediaPlayer?
    /// スクリーンに静止画（画像・PDF のページ）を貼るエンティティ（静止画を出すあいだだけ有効）
    private(set) var stillScreen: ModelEntity?
    /// スクリーンに貼った（貼っている途中の）静止画
    @ObservationIgnored private var shownStill: StillPicture.ID?
    /// 映像・静止画を出していないときのスクリーンの面。出しているあいだは隠す
    /// （隠さないと、縦長の画像などで、マスキングで覆い切れない端にスクリーンの面が見える）
    @ObservationIgnored private let screenSurface: Entity?
    private(set) var screenFrame: ScreenFrame
    private let speakers = SpatialSpeakers()
    let lighting: LightingDirector
    @ObservationIgnored private var currentFormat: VideoFormat?
    @ObservationIgnored private var currentStereo = StereoPacking.mono
    /// スクリーンの VideoMaterial が映している renderer（3D と 2D を切り替えると、エンジンが作り直す）
    @ObservationIgnored private var screenRenderer: AVSampleBufferVideoRenderer?
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
        screenSurface = environment.screenSurface
        let screen = environment.layout.screen
        screenAnchor.name = "ScreenAnchor"
        screenAnchor.position = SIMD3(screen.center.x, screen.center.y, screen.center.z + 0.08)
        environment.model.addChild(screenAnchor)
        let seat = environment.layout.seat(id: preferences.seatID) ?? environment.layout.seat(id: Preferences.defaultSeat)
        if let seat {
            environment.sit(at: seat)
        }
        environment.root.components.set(ReverbComponent(reverb: preferences.room.reverb))
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
        // VideoMaterial は舞台を作るたびに 1 回だけ作る。作ると renderer に「映す先」が足される（コマを渡している最中は足せず、落ちる）。
        // 映画館に入るときは、ファイルを閉じている（または映す先が無いので renderer がコマを受け取っていない）ので、ここでは足せる。
        // 前の舞台の VideoMaterial を使い回すと、映画館を閉じたときに RealityKit 側の映す先が片付けられていて、映らない
        // 前のスクリーンを外してから（コマを渡すのを止めてから）、新しい VideoMaterial を作ってつなぐ
        engine.detachVideoScreen()
        self.engine = engine
        if let material = connect(engine), let mesh = try? ScreenMesh.make(frame: screenFrame, spec: layout.screen) {
            let screen = makeVideoScreen(mesh: mesh, material: material)
            Diagnostics.log("VideoScreen を作った position=\(screen.position) bounds=\(screen.visualBounds(relativeTo: nil).extents)")
        }
        speakers.build(layout: layout, ring: engine.ring, parent: environment.model)
        speakers.play()
    }

    /// 再生のエンジンから外す（映画館を閉じた・別の舞台に替わった）。同じ renderer を、古い VideoMaterial が持ったままにしない
    func detach() {
        speakers.remove()
        // スクリーンを外したら、次のスクリーンをつなぐまでコマを渡さない（外したスクリーンの映す先に渡し続けると、
        // 次の VideoMaterial を作るときに「渡している最中」になって映らない）
        if videoScreen != nil {
            engine?.detachVideoScreen()
        }
        videoScreen?.removeFromParent()
        videoScreen = nil
        screenRenderer = nil
        isShowingVideo = false
        engine = nil
    }

    /// 映像を映すスクリーンを作って部屋に置く
    @discardableResult
    private func makeVideoScreen(mesh: MeshResource, material: VideoMaterial) -> ModelEntity {
        let screen = ModelEntity(mesh: mesh, materials: [material])
        screen.name = "VideoScreen"
        // 無効にしない（有効に戻すと RealityKit が renderer に映す先を足し直し、コマを渡している最中だと足せずに真っ黒になる）。
        // 映像が無いときは透明にして隠す
        screen.components.set(OpacityComponent(opacity: isShowingVideo ? 1 : 0))
        environment.model.addChild(screen)
        videoScreen = screen
        return screen
    }

    /// エンジンの今の renderer の VideoMaterial を作って、スクリーンとしてつなぐ（コマを渡していない間に作る）
    private func connect(_ engine: MediaPlayer) -> VideoMaterial? {
        var created: VideoMaterial?
        engine.attachVideoScreen {
            let renderer = engine.videoRenderer
            created = VideoMaterial(videoRenderer: renderer)
            screenRenderer = renderer
        }
        return created
    }

    /// エンジンが renderer を作り直したら（3D と 2D の切り替え）、新しい renderer の VideoMaterial を貼ったスクリーンに替える。
    /// 同じスクリーンのまま VideoMaterial を差し替えると、1 回おきに映らなかった（Simulator）ので、スクリーンごと作り直す。
    /// 作り直した renderer には、スクリーンをつなぐまでコマを渡さないので、ここで作っても渡している最中にはならない
    private func followRenderer(of engine: MediaPlayer) {
        guard let old = videoScreen, engine.videoRenderer !== screenRenderer, let mesh = old.model?.mesh,
              let material = connect(engine) else {
            return
        }
        old.removeFromParent()
        makeVideoScreen(mesh: mesh, material: material)
        Diagnostics.log("VideoScreen を作り直した（renderer を付け替えた）")
    }

    func setRoom(_ room: SpatialSpeakers.Room) {
        root.components.set(ReverbComponent(reverb: room.reverb))
    }

    /// 映像の形式に合わせて、スクリーンの映像の範囲とマスキングを変える。映像が無ければ（音楽）映像を消す
    /// stereo は左右の目の並べ方（3D の映像なら、スクリーンとマスキングを片目の絵の縦横比に合わせる）
    func update(format: VideoFormat?, hasVideo: Bool, stereo: StereoPacking) {
        let visible = hasVideo && format != nil
        if let screen = videoScreen, visible != isShowingVideo {
            Diagnostics.log("VideoScreen visible=\(visible) format=\(String(describing: format))")
            screen.components.set(OpacityComponent(opacity: visible ? 1 : 0))
            isShowingVideo = visible
        }
        updateSurface()
        guard let format, format != currentFormat || stereo != currentStereo else {
            return
        }
        currentFormat = format
        currentStereo = stereo
        let frame = ScreenFrame(aspect: Float(stereo.eyeAspect(frameAspect: format.visibleAspect)), spec: layout.screen)
        screenFrame = frame
        let rotation = VideoRotation(rawValue: format.rotation) ?? .none
        if let mesh = try? ScreenMesh.make(frame: frame, spec: layout.screen, rotation: rotation) {
            videoScreen?.model?.mesh = mesh
        }
        environment.setMasking(frame: frame)
    }

    /// 静止画（画像・PDF のページ）をスクリーンに貼る。nil なら外す。
    /// RealityView の update から何度も呼ばれるので、貼る物が変わったときだけ作り直す
    func show(still: StillPicture?) {
        guard let still else {
            stillScreen?.isEnabled = false
            shownStill = nil
            updateSurface()
            return
        }
        guard still.id != shownStill else {
            return
        }
        shownStill = still.id
        currentFormat = nil
        let frame = ScreenFrame(aspect: Float(still.aspect), spec: layout.screen)
        Task {
            // 大きな画像を GPU へ送るのは重いので、非同期で作る
            guard let texture = try? await TextureResource(image: still.image, options: .init(semantic: .color)),
                  let mesh = try? ScreenMesh.make(frame: frame, spec: layout.screen),
                  shownStill == still.id else {
                return
            }
            // 部屋のマテリアルと同じく、トーンマップをかけない（画像の色のまま）
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            material.color = .init(tint: .white, texture: .init(texture))
            if let screen = stillScreen {
                screen.model?.mesh = mesh
                screen.model?.materials = [material]
            } else {
                let screen = ModelEntity(mesh: mesh, materials: [material])
                screen.name = "StillScreen"
                environment.model.addChild(screen)
                stillScreen = screen
            }
            stillScreen?.isEnabled = true
            updateSurface()
            if screenFrame != frame {
                screenFrame = frame
            }
            environment.setMasking(frame: frame)
        }
    }

    /// スクリーンの面は、映像・静止画を出していないときだけ見せる
    private func updateSurface() {
        let showing = isShowingVideo || stillScreen?.isEnabled == true
        if screenSurface?.isEnabled != !showing {
            screenSurface?.isEnabled = !showing
        }
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
        if let engine = player.engine {
            followRenderer(of: engine)
        }
        let hasVideo = player.info.map { !$0.isAudioOnly } ?? false
        // 静止画を出しているあいだも、上映中と同じく客電を落とし、その画像の色で部屋を照らす
        let still = player.still
        let values = lighting.step(
            deltaTime: deltaTime,
            playing: player.isPlaying || still != nil,
            hasVideo: hasVideo || still != nil,
            preferences: preferences,
            light: still?.light ?? player.engine?.screenLight()
        )
        environment.lighting.update(values)
    }
}
