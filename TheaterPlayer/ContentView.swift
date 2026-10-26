//
//  ContentView.swift
//  TheaterPlayer
//
//  Created by 村石 拓海 on 2024/05/12.
//

import RealityKit
import RealityKitContent
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Model3D(named: "Scene", bundle: realityKitContentBundle)
                .padding(.bottom, 50)

            Text("Hello, world!")

            ToggleImmersiveSpaceButton()
        }
        .padding()
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
