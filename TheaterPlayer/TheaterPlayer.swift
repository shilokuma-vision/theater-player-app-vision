//
//  TheaterPlayer.swift
//  TheaterPlayer
//
//  Created by 村石 拓海 on 2024/05/12.
//

import SwiftUI

@main
struct TheaterPlayer: App {
    @State private var appModel = AppModel()
    @State private var immersion: ImmersionStyle = .full

    var body: some Scene {
        WindowGroup(id: appModel.libraryWindowID) {
            rootView
                .environment(appModel)
        }
        .defaultSize(width: 980, height: 720)

        // 映画館。開閉はライブラリの「映画館に入る」と、操作パネルの「映画館を出る」から行う。
        // open / closed は実際に表示・非表示になったときにだけ書き換える（システムの操作でも開閉するため）
        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            TheaterView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: $immersion, in: .full)
    }

    /// 撮影モード（ScreenshotDemo）のときは、撮る画面を開く
    @ViewBuilder private var rootView: some View {
        switch ScreenshotDemo.scene {
        case .home, nil:
            LibraryView()
        }
    }
}
