//
//  TheaterStage.swift
//  TheaterPlayer
//
//  映画館の空間（RealityKit）。映画館のモデルと、スクリーンの映像・静止画（画像・PDF）・空間オーディオのスピーカー・
//  照明の演出・開演のブザー・席の移動をまとめる。
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
    private(set) var screenFrame: ScreenFrame {
        didSet { fitScreenTarget() }
    }
    private let speakers = SpatialSpeakers()
    private let buzzer = TheaterBuzzer()
    /// ブザーを鳴らした開演（ShowDirector.performance。開演ごとに 1 回だけ鳴らす）
    @ObservationIgnored private var buzzedPerformance = 0
    let lighting: LightingDirector
    /// 全体の座席表の寸法（座席のページを開くたびに求め直さない）
    let seatChart: SeatChart
    @ObservationIgnored private var currentFormat: VideoFormat?
    @ObservationIgnored private var currentStereo = StereoPacking.mono
    /// スクリーンの VideoMaterial が映している renderer（3D と 2D を切り替えると、エンジンが作り直す）
    @ObservationIgnored private var screenRenderer: AVSampleBufferVideoRenderer?
    /// 幕（左右のマスキング）を閉じているか
    @ObservationIgnored private var curtainClosed = false
    /// 字幕・音楽の表示を置く、スクリーンの中心の手前の点（表示は、さらに曲面の出っ張りの分だけ手前に置く。overlayDepth）
    let screenAnchor = Entity()
    /// スクリーンをつまむ（視線＋ピンチ）ための当たり判定。見た目は無く、映像の範囲に合わせる（TheaterView が、つまんだら操作パネルを出す）。
    /// 字幕・音楽の表示（つまめない）より奥に置き、手前に置いた操作できる表示があれば、そちらが先につままれるようにする
    let screenTarget = Entity()
    static let screenTargetName = "ScreenTarget"
    /// 何回目に作った舞台か（診断のログ用）
    @ObservationIgnored var number = 0

    static func load(preferences: Preferences) async throws -> TheaterStage {
        let environment = try await TheaterEnvironment.load(bundle: .main)
        return TheaterStage(environment: environment, preferences: preferences)
    }

    private init(environment: TheaterEnvironment, preferences: Preferences) {
        self.environment = environment
        lighting = LightingDirector(initialHouse: preferences.houseLevel)
        screenFrame = ScreenFrame(aspect: 2.0, spec: environment.layout.screen)
        seatChart = SeatChart(rows: environment.layout.seatRows, sections: environment.layout.seatSections())
        screenSurface = environment.screenSurface
        let screen = environment.layout.screen
        screenAnchor.name = "ScreenAnchor"
        screenAnchor.position = SIMD3(screen.center.x, screen.center.y, screen.center.z + 0.08)
        environment.model.addChild(screenAnchor)
        screenTarget.name = Self.screenTargetName
        // 遠くのスクリーンなので、視線＋ピンチ（間接）だけを受ける
        screenTarget.components.set(InputTargetComponent(allowedInputTypes: .indirect))
        screenAnchor.addChild(screenTarget)
        fitScreenTarget()
        let seat = environment.layout.seat(id: preferences.seatID) ?? environment.layout.seat(id: Preferences.defaultSeat)
        if let seat {
            environment.sit(at: seat)
        }
        environment.root.components.set(ReverbComponent(reverb: preferences.room.reverb))
        buzzer.build(layout: environment.layout, parent: environment.model)
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
        // 前の舞台の VideoMaterial を使い回すと、映画館を閉じたときに RealityKit 側の映す先が片付けられていて、映らない。
        // 前の舞台の VideoMaterial を付けた renderer も使わない（映す先が残っていて、新しい VideoMaterial に映らない）。
        // エンジンは、つなぐたびに新しい renderer を渡す（connect）。
        // 前のスクリーンを外してから（コマを渡すのを止めてから）、新しい VideoMaterial を作ってつなぐ
        Diagnostics.log("舞台#\(number) を再生とつなぐ \(ScreenProbe.remaining())")
        engine.detachVideoScreen()
        self.engine = engine
        if let material = connect(engine), let mesh = try? ScreenMesh.make(frame: screenFrame, spec: layout.screen) {
            let screen = makeVideoScreen(mesh: mesh, material: material)
            Diagnostics.log(
                "VideoScreen を作った 舞台#\(number) position=\(screen.position) bounds=\(screen.visualBounds(relativeTo: nil).extents) " +
                    ScreenProbe.describe(screen)
            )
        }
        speakers.build(layout: layout, ring: engine.ring, parent: environment.model)
        speakers.play()
    }

    /// 再生のエンジンから外す（映画館を閉じた・別の舞台に替わった）。同じ renderer を、古い VideoMaterial が持ったままにしない
    func detach() {
        Diagnostics.log("舞台#\(number) を再生から外す \(ScreenProbe.describe(videoScreen))")
        ScreenProbe.track(videoScreen, "舞台#\(number) の VideoScreen")
        ScreenProbe.track((videoScreen?.model?.materials.first as? VideoMaterial)?.__videoResource, "舞台#\(number) の VideoMaterial")
        speakers.remove()
        buzzer.stop()
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
        engine.attachVideoScreen { renderer in
            let material = VideoMaterial(videoRenderer: renderer)
            created = material
            screenRenderer = renderer
            Diagnostics.log(
                "VideoMaterial を作った 舞台#\(number) material=\(Diagnostics.id(material.__videoResource)) " +
                    "renderer=\(Diagnostics.id(renderer)) material.renderer=\(Diagnostics.id(material.videoRenderer))"
            )
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
        ScreenProbe.track(old, "舞台#\(number) の古い VideoScreen（renderer を付け替えた）")
        old.removeFromParent()
        let screen = makeVideoScreen(mesh: mesh, material: material)
        Diagnostics.log("VideoScreen を作り直した（renderer を付け替えた） \(ScreenProbe.describe(screen))")
    }

    func setRoom(_ room: SpatialSpeakers.Room) {
        root.components.set(ReverbComponent(reverb: room.reverb))
    }

    /// 映像の形式に合わせて、スクリーンの映像の範囲とマスキングを変える。映像が無ければ（音楽）映像を消す。
    /// stereo は左右の目の並べ方（3D の映像なら、スクリーンとマスキングを片目の絵の縦横比に合わせる）。
    /// ceremony：開演の流れの段階。流しているあいだは映像を出さず（白いスクリーンの前で幕を開ける）、ブザーと 1 段目の暗転のあいだは幕を閉じる
    func update(format: VideoFormat?, hasVideo: Bool, stereo: StereoPacking, ceremony: ShowPhase? = nil) {
        let visible = hasVideo && format != nil && ceremony == nil
        if let screen = videoScreen, visible != isShowingVideo {
            Diagnostics.log("VideoScreen visible=\(visible) format=\(String(describing: format))")
            screen.components.set(OpacityComponent(opacity: visible ? 1 : 0))
            isShowingVideo = visible
        }
        updateSurface()
        if let format, format != currentFormat || stereo != currentStereo {
            currentFormat = format
            currentStereo = stereo
            let frame = ScreenFrame(aspect: Float(stereo.eyeAspect(frameAspect: format.visibleAspect)), spec: layout.screen)
            screenFrame = frame
            let rotation = VideoRotation(rawValue: format.rotation) ?? .none
            if let mesh = try? ScreenMesh.make(frame: frame, spec: layout.screen, rotation: rotation) {
                videoScreen?.model?.mesh = mesh
            }
        }
        // 映像の形式が分かる前（開いた直後）は、今の範囲のまま幕だけ閉じる
        if format != nil || ceremony != nil {
            placeMasking(frame: screenFrame, closed: ceremony?.closesCurtain ?? false)
        }
    }

    /// マスキングを動かす。幕を閉じる・開けるときは、開演の流れの秒数で動かす
    private func placeMasking(frame: ScreenFrame, closed: Bool) {
        guard closed != curtainClosed else {
            environment.setMasking(frame: frame, closed: closed)
            return
        }
        curtainClosed = closed
        let program = ShowProgram.standard
        environment.setMasking(frame: frame, closed: closed, duration: closed ? program.curtainClose : program.curtainOpen)
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
            placeMasking(frame: frame, closed: false)
        }
    }

    /// スクリーンをつまむ当たり判定を、今の映像の範囲に合わせる
    private func fitScreenTarget() {
        let shape = ShapeResource.generateBox(width: screenFrame.width, height: screenFrame.height, depth: 0.1)
        screenTarget.components.set(CollisionComponent(shapes: [shape]))
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
        setMasking(aspect: 2.0)
    }

    /// 縦横比 aspect の範囲にマスキングを合わせる（映像の形式は忘れる。次に映像を出すときに合わせ直す）
    func setMasking(aspect: Float) {
        currentFormat = nil
        let frame = ScreenFrame(aspect: aspect, spec: layout.screen)
        // RealityView の update から何度も呼ばれるので、変わったときだけ書き換える（見ている View を作り直させない）
        if screenFrame != frame {
            screenFrame = frame
        }
        placeMasking(frame: frame, closed: false)
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

    /// isShowingWeb：スクリーンの前に Web のページ（デバッグの YouTube）を出している。
    /// 上映中と同じく客電を落とす。ページの色は分からないので、スクリーンの照り返しは無し
    func update(deltaTime: Double, player: PlayerModel, preferences: Preferences, isShowingWeb: Bool = false) {
        if let engine = player.engine {
            followRenderer(of: engine)
        }
        ScreenProbe.report(stage: number, screen: videoScreen, room: environment.model, engine: player.engine)
        // 開演の流れは、映画館が描き始めてから進める
        player.show.theaterDidRender()
        let phase = player.showPhase
        if phase == .buzzer, player.show.performance != buzzedPerformance {
            buzzedPerformance = player.show.performance
            buzzer.play(volume: preferences.volume)
        } else if player.show.ceremony == nil {
            // 開演の流れを省いて始めた・止めた
            buzzer.stop()
        }
        // 開演の流れのあいだは映像を出さないので、映像の色で部屋を照らさない
        let hasVideo = (player.info.map { !$0.isAudioOnly } ?? false) && player.show.ceremony == nil
        // 静止画を出しているあいだも、その画像の色で部屋を照らす
        let still = player.still
        let values = lighting.step(
            deltaTime: deltaTime,
            // Web のページを出しているあいだも、上映中と同じく客電を落とす
            phase: isShowingWeb ? .feature : phase,
            hasVideo: (hasVideo || still != nil) && !isShowingWeb,
            preferences: preferences,
            light: still?.light ?? player.engine?.screenLight()
        )
        environment.lighting.update(values)
    }
}
