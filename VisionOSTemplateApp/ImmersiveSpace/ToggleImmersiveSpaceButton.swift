//
//  ToggleImmersiveSpaceButton.swift
//  VisionOSTemplateApp
//
//  Immersive Space を開閉するボタン。
//

import SwiftUI

struct ToggleImmersiveSpaceButton: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some View {
        Button {
            Task {
                await toggleImmersiveSpace()
            }
        } label: {
            Text(appModel.immersiveSpaceState == .open ? "Hide Immersive Space" : "Show Immersive Space")
        }
        .disabled(appModel.immersiveSpaceState == .inTransition)
        .fontWeight(.semibold)
    }

    /// 開いていれば閉じ、閉じていれば開く。
    /// open / closed にするのは ImmersiveView の onAppear / onDisappear だけにする（システムの操作でも開閉するため）。
    /// ここでは開閉の途中（inTransition）にすることと、開けなかったときに closed へ戻すことだけを行う
    private func toggleImmersiveSpace() async {
        switch appModel.immersiveSpaceState {
        case .open:
            appModel.immersiveSpaceState = .inTransition
            await dismissImmersiveSpace()
        case .closed:
            appModel.immersiveSpaceState = .inTransition
            switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
            case .opened:
                break
            case .userCancelled, .error:
                appModel.immersiveSpaceState = .closed
            @unknown default:
                appModel.immersiveSpaceState = .closed
            }
        case .inTransition:
            // 開閉の途中はボタンを無効にしているので来ない
            break
        }
    }
}
