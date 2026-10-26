//
//  RealityKitContentTests.swift
//  VisionOSTemplateAppTests
//
//  Packages/RealityKitContent の素材が、ビルドでパッケージのバンドルに入って読み込めることを確認する。
//  rkassets に素材を足したら arguments にも足す。
//

import RealityKit
import RealityKitContent
import Testing

struct RealityKitContentTests {
    @Test(arguments: ["Scene", "Immersive"])
    func sceneLoads(name: String) async throws {
        _ = try await Entity(named: name, in: realityKitContentBundle)
    }
}
