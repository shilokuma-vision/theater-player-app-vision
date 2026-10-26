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

    var body: some Scene {
        WindowGroup {
            rootView
                .environment(appModel)
        }

        // 開閉は ToggleImmersiveSpaceButton から行う。open / closed は実際に表示・非表示になったときにだけ書き換える
        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }

    /// 撮影モード（ScreenshotDemo）のときは、撮る画面を開く
    @ViewBuilder private var rootView: some View {
        switch ScreenshotDemo.scene {
        case .home, nil:
            ContentView()
        }
    }
}
