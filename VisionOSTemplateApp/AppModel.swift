//
//  AppModel.swift
//  VisionOSTemplateApp
//
//  アプリ全体で共有する状態。VisionOSTemplateApp で 1 つ作り、environment で各 View に渡す。
//

import Observation

@Observable
final class AppModel {
    /// Immersive Space の開閉の状態
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }

    /// ImmersiveSpace の id。openImmersiveSpace(id:) に渡す
    let immersiveSpaceID = "ImmersiveSpace"

    var immersiveSpaceState = ImmersiveSpaceState.closed
}
