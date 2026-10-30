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
            Diagnostics.log("RealityView の make を始めた（前の舞台#\(appModel.activeStage?.number ?? 0)）")
            let anchor = Entity()
            anchor.name = "ImmersiveRoot"
            content.add(anchor)
            await addControlPanel(to: content, attachments: attachments)
            do {
                let stage = try await TheaterStage.load(preferences: appModel.preferences)
                anchor.addChild(stage.root)
                // 舞台は 1 つだけにする（RealityView の make が 2 回呼ばれて、舞台が 2 つできることがあった。
                // 同じ renderer に VideoMaterial が 2 つ付くと、映らないほうに映像が行く）
                appModel.activeStage?.detach()
                appModel.activeStage = stage
                appModel.stagesCreated += 1
                stage.number = appModel.stagesCreated
                Diagnostics.log("舞台を作った（\(appModel.stagesCreated) 回目） state=\(appModel.player.state)")
                if let engine = appModel.player.engine {
                    stage.attach(engine)
                }
                self.stage = stage
                // 購読の閉包では self（TheaterView）を掴まない。掴むと @State の updates → 購読 → 閉包 → @State の循環になり、
                // 映画館を閉じても舞台（映画館のモデル）が解放されない。舞台は @State と AppModel が持つので、ここでは弱く持つ
                updates = content.subscribe(to: SceneEvents.Update.self) { [weak stage, appModel] event in
                    stage?.update(
                        deltaTime: event.deltaTime,
                        player: appModel.player,
                        preferences: appModel.preferences,
                        isShowingWeb: appModel.isShowingYouTube
                    )
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
            // デバッグの YouTube を出しているあいだは、止めた動画・静止画を隠し、マスキングを YouTube のページ（16:9）に合わせる
            let showsWeb = appModel.isShowingYouTube
            let hasVideo = !showsWeb && (player.info.map { !$0.isAudioOnly } ?? false)
            stage.show(still: showsWeb ? nil : player.still)
            if hasVideo {
                stage.update(format: player.videoFormat, hasVideo: true, stereo: player.stereoPacking, ceremony: player.show.ceremony)
            } else {
                stage.update(format: nil, hasVideo: false, stereo: .mono)
                if showsWeb {
                    stage.setMasking(aspect: 16 / 9)
                } else if player.still == nil {
                    // 静止画のときは、マスキングを静止画に合わせる（show(still:)）
                    stage.resetMasking()
                }
            }
            place(attachments.entity(for: "subtitles"), on: stage, width: stage.screenFrame.width, enabled: hasVideo)
            place(
                attachments.entity(for: "nowPlaying"),
                on: stage,
                width: min(stage.screenFrame.width, 16),
                enabled: !showsWeb && player.info?.isAudioOnly == true
            )
            #if DEBUG
            place(attachments.entity(for: "youTube"), on: stage, width: stage.screenFrame.width, enabled: showsWeb)
            #endif
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
            #if DEBUG
            Attachment(id: "youTube") {
                YouTubeScreen()
            }
            #endif
        }
        .gesture(panelDrag)
        #if DEBUG
        // 止めていた動画をまた再生したら（操作パネルの再生・ライブラリで開いた）、YouTube を閉じてスクリーンを返す
        .onChange(of: appModel.player.isPlaying) {
            if appModel.player.isPlaying {
                appModel.youTube.close()
            }
        }
        #endif
        // open / closed は実際に表示・非表示になったときにだけ書き換える（システムの操作でも開閉するため）
        .onAppear {
            Diagnostics.log("映画館を出した（onAppear）")
            appModel.immersiveSpaceState = .open
        }
        .onDisappear {
            Diagnostics.log("映画館を片付ける（onDisappear） 舞台#\(stage?.number ?? 0) activeStage=#\(appModel.activeStage?.number ?? 0)")
            ScreenProbe.track(stage, "舞台#\(stage?.number ?? 0)")
            ScreenProbe.track(stage?.root, "舞台#\(stage?.number ?? 0) の root")
            stage?.detach()
            if appModel.activeStage === stage {
                appModel.activeStage = nil
            }
            appModel.player.close()
            #if DEBUG
            appModel.youTube.close()
            #endif
            // 「映画館を出る」は .inTransition にして、ライブラリを開いてから閉じる。
            // それ以外（Digital Crown などシステムの操作で閉じた）は、ウィンドウが 1 つも無くなるので、ここでライブラリを開き直す
            if appModel.immersiveSpaceState != .inTransition, !appModel.isLibraryOpen {
                openWindow(id: appModel.libraryWindowID)
            }
            appModel.immersiveSpaceState = .closed
        }
    }

    /// 操作パネル（添付）と、その下のつまみを置く。パネルの大きさが変わったら（畳む・ページを替える）、つまみを付いて行かせる。
    /// つまみは、パネルを動かしている間は掴んでいる見た目にする
    private func addControlPanel(to content: RealityViewContent, attachments: RealityViewAttachments) async {
        let root = Entity()
        root.name = PanelPlacement.rootName
        PanelPlacement.place(root, at: appModel.preferences.panelPosition ?? PanelPlacement.defaultPosition)
        content.add(root)
        let handle = await PanelPlacement.makeHandle()
        root.addChild(handle)
        if let panel = attachments.entity(for: "controls") {
            root.addChild(panel)
            PanelPlacement.follow(handle: handle, panel: panel)
            // updates と同じく、self を掴まない（appModel だけを持つ）
            panelUpdates = content.subscribe(to: SceneEvents.Update.self) { [weak handle, weak panel, appModel] event in
                if let handle, let panel {
                    PanelPlacement.follow(handle: handle, panel: panel)
                    PanelPlacement.update(handle: handle, grabbing: appModel.isMovingPanel, deltaTime: event.deltaTime)
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
