//
//  TheaterView.swift
//  TheaterPlayer
//
//  映画館（ImmersiveSpace の中身）。映画館のモデルを読み、手元の操作パネル・スクリーンの字幕・音楽の表示を置く。
//

import RealityKit
import SwiftUI
import TheaterMedia
import TheaterScene

struct TheaterView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var stage: TheaterStage?
    @State private var updates: EventSubscription?
    @State private var loadError: String?
    /// 操作パネルとつまみを入れる親（つまみをドラッグすると、これごと動かす）
    @State private var panelRoot: Entity?
    @State private var panelUpdates: EventSubscription?
    /// ドラッグを始めたときの、つまみをつまんだ所からパネルの位置までの差
    @State private var dragOffset: SIMD3<Float>?

    var body: some View {
        RealityView { content, attachments in
            let anchor = Entity()
            anchor.name = "ImmersiveRoot"
            content.add(anchor)
            addControlPanel(to: content, attachments: attachments)
            do {
                let stage = try await TheaterStage.load(preferences: appModel.preferences)
                anchor.addChild(stage.root)
                // 舞台は 1 つだけにする（RealityView の make が 2 回呼ばれて、舞台が 2 つできることがあった。
                // 同じ renderer に VideoMaterial が 2 つ付くと、映らないほうに映像が行く）
                appModel.activeStage?.detach()
                appModel.activeStage = stage
                appModel.stagesCreated += 1
                Diagnostics.log("舞台を作った（\(appModel.stagesCreated) 回目）")
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
            // 操作パネルを、覚えている位置（元に戻したら既定の位置）へ。動かしている間はドラッグに任せる
            if let panelRoot, dragOffset == nil {
                let position = appModel.preferences.panelPosition ?? PanelPlacement.defaultPosition
                if panelRoot.position != position {
                    PanelPlacement.place(panelRoot, at: position)
                }
            }
            guard let stage else {
                return
            }
            let player = appModel.player
            let hasVideo = player.info.map { !$0.isAudioOnly } ?? false
            stage.show(still: player.still)
            if hasVideo {
                stage.update(format: player.videoFormat, hasVideo: true, stereo: player.stereoPacking, ceremony: player.show.ceremony)
            } else {
                stage.update(format: nil, hasVideo: false, stereo: .mono)
                // 静止画のときは、マスキングを静止画に合わせる（show(still:)）
                if player.still == nil {
                    stage.resetMasking()
                }
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
        .gesture(panelDrag)
        // open / closed は実際に表示・非表示になったときにだけ書き換える（システムの操作でも開閉するため）
        .onAppear {
            appModel.immersiveSpaceState = .open
        }
        .onDisappear {
            stage?.detach()
            if appModel.activeStage === stage {
                appModel.activeStage = nil
            }
            appModel.player.close()
            // 「映画館を出る」は .inTransition にして、ライブラリを開いてから閉じる。
            // それ以外（Digital Crown などシステムの操作で閉じた）は、ウィンドウが 1 つも無くなるので、ここでライブラリを開き直す
            if appModel.immersiveSpaceState != .inTransition, !appModel.isLibraryOpen {
                openWindow(id: appModel.libraryWindowID)
            }
            appModel.immersiveSpaceState = .closed
        }
    }

    /// 操作パネル（添付）と、その下のつまみを置く。パネルの大きさが変わったら（畳む・ページを替える）、つまみを付いて行かせる
    private func addControlPanel(to content: RealityViewContent, attachments: RealityViewAttachments) {
        let root = Entity()
        root.name = PanelPlacement.rootName
        PanelPlacement.place(root, at: appModel.preferences.panelPosition ?? PanelPlacement.defaultPosition)
        content.add(root)
        let handle = PanelPlacement.makeHandle()
        root.addChild(handle)
        if let panel = attachments.entity(for: "controls") {
            root.addChild(panel)
            PanelPlacement.follow(handle: handle, panel: panel)
            panelUpdates = content.subscribe(to: SceneEvents.Update.self) { [weak handle, weak panel] _ in
                if let handle, let panel {
                    PanelPlacement.follow(handle: handle, panel: panel)
                }
            }
        }
        panelRoot = root
    }

    /// つまみをドラッグして、操作パネルを動かす。離したら位置を覚える
    private var panelDrag: some Gesture {
        DragGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard value.entity.name == PanelPlacement.handleName, let panelRoot else {
                    return
                }
                let location = value.convert(value.location3D, from: .local, to: .scene)
                if dragOffset == nil {
                    let start = value.convert(value.startLocation3D, from: .local, to: .scene)
                    dragOffset = panelRoot.position(relativeTo: nil) - start
                    appModel.isMovingPanel = true
                }
                PanelPlacement.place(panelRoot, at: location + (dragOffset ?? .zero))
            }
            .onEnded { value in
                guard value.entity.name == PanelPlacement.handleName, let panelRoot else {
                    return
                }
                appModel.preferences.panelPosition = panelRoot.position(relativeTo: nil)
                dragOffset = nil
                appModel.isMovingPanel = false
                appModel.panelInteraction += 1
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
