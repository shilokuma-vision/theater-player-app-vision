//
//  ImmersiveView.swift
//  TheaterPlayer
//
//  Immersive Space（周りの空間）に出す内容。RealityKitContent の Immersive.usda を読み込んで置く。
//

import RealityKit
import RealityKitContent
import SwiftUI

struct ImmersiveView: View {
    var body: some View {
        RealityView { content in
            if let immersiveContentEntity = try? await Entity(named: "Immersive", in: realityKitContentBundle) {
                content.add(immersiveContentEntity)
            }
        }
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
