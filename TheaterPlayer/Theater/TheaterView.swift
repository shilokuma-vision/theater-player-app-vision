//
//  TheaterView.swift
//  TheaterPlayer
//
//  映画館（ImmersiveSpace の中身）。映画館のモデルを読み、手元の操作パネル・スクリーンの字幕・音楽の表示を置く。
//

import RealityKit
import SwiftUI
import TheaterScene

struct TheaterView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var stage: TheaterStage?
    @State private var updates: EventSubscription?
    @State private var loadError: String?

    /// 操作パネルの位置（座った目の前、ひざの少し上。目へ向けて傾ける）
    static let panelPosition = SIMD3<Float>(0, 0.78, -0.6)

    var body: some View {
        RealityView { content, attachments in
            let anchor = Entity()
            anchor.name = "ImmersiveRoot"
            content.add(anchor)
            if let panel = attachments.entity(for: "controls") {
                panel.position = Self.panelPosition
                panel.orientation = simd_quatf(angle: -.pi / 5, axis: SIMD3(1, 0, 0))
                content.add(panel)
            }
            do {
                let stage = try await TheaterStage.load(preferences: appModel.preferences)
                anchor.addChild(stage.root)
                if let engine = appModel.player.engine {
                    stage.attach(engine)
                }
                self.stage = stage
                updates = content.subscribe(to: SceneEvents.Update.self) { event in
                    stage.update(deltaTime: event.deltaTime, player: appModel.player, preferences: appModel.preferences)
                }
            } catch {
                loadError = error.localizedDescription
            }
        } update: { _, attachments in
            guard let stage else {
                return
            }
            let player = appModel.player
            let hasVideo = player.info.map { !$0.isAudioOnly } ?? false
            if hasVideo {
                stage.update(format: player.videoFormat, hasVideo: true)
            } else {
                stage.update(format: nil, hasVideo: false)
                stage.resetMasking()
            }
            place(attachments.entity(for: "subtitles"), on: stage, width: stage.screenFrame.width, enabled: hasVideo)
            place(
                attachments.entity(for: "nowPlaying"),
                on: stage,
                width: min(stage.screenFrame.width, 16),
                enabled: player.info?.isAudioOnly ?? false
            )
        } attachments: {
            Attachment(id: "controls") {
                ControlPanel(stage: stage, loadError: loadError)
            }
            Attachment(id: "subtitles") {
                SubtitleOverlay(
                    cues: appModel.player.subtitles,
                    aspect: stage.map { Double($0.screenFrame.width / $0.screenFrame.height) } ?? 2
                )
            }
            Attachment(id: "nowPlaying") {
                NowPlayingScreen()
            }
        }
        // open / closed は実際に表示・非表示になったときにだけ書き換える（システムの操作でも開閉するため）
        .onAppear {
            appModel.immersiveSpaceState = .open
        }
        .onDisappear {
            stage?.detach()
            appModel.player.close()
            // 「映画館を出る」は .inTransition にして、ライブラリを開いてから閉じる。
            // それ以外（Digital Crown などシステムの操作で閉じた）は、ウィンドウが 1 つも無くなるので、ここでライブラリを開き直す
            if appModel.immersiveSpaceState != .inTransition, !appModel.isLibraryOpen {
                openWindow(id: appModel.libraryWindowID)
            }
            appModel.immersiveSpaceState = .closed
        }
    }

    /// スクリーンの手前（曲面の端より手前）に、映像の幅に合わせた大きさで置く
    private func place(_ entity: ViewAttachmentEntity?, on stage: TheaterStage, width: Float, enabled: Bool) {
        guard let entity else {
            return
        }
        if entity.parent !== stage.screenAnchor {
            stage.screenAnchor.addChild(entity)
        }
        entity.isEnabled = enabled
        entity.position = SIMD3(0, 0, stage.overlayDepth(width: width))
        let natural = entity.attachment.bounds.extents.x
        if natural > 0 {
            entity.scale = SIMD3(repeating: width / natural)
        }
    }
}
