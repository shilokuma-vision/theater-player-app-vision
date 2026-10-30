//
//  PanelHandleTests.swift
//  TheaterPlayerTests
//
//  操作パネルのつまみ（Materials/PanelHandle.usda のマテリアル・当たり判定・掴んだときの変化）。
//

import RealityKit
import Testing
@testable import TheaterPlayer

@MainActor
struct PanelHandleTests {
    /// マテリアル（見ている間・掴んでいる間に広がるカプセル）が読め、大きさと明るさを渡せる
    @Test func loadsTheHandleMaterial() async throws {
        let handle = await PanelPlacement.makeHandle()
        let material = try #require(handle.model?.materials.first as? ShaderGraphMaterial)
        let names = Set(material.parameterNames)
        #expect(names.isSuperset(of: ["Grab", "PlaneSize", "IdleSize", "ActiveSize", "IdleOpacity", "HoverOpacity", "GrabOpacity"]))
        #expect(try grab(of: handle) == 0)
        #expect(handle.components[HoverEffectComponent.self] != nil)
    }

    /// 当たり判定は今までと同じ大きさで、上の端がパネルの下の端（つまみの 0.022 m 上）にそろう
    @Test func hitAreaReachesThePanelEdge() async throws {
        let handle = await PanelPlacement.makeHandle()
        let shape = try #require(handle.components[CollisionComponent.self]?.shapes.first)
        let bounds = shape.bounds
        #expect(abs(bounds.max.y - 0.022) < 0.0001)
        #expect(abs(bounds.extents.x - 0.22) < 0.0001)
        #expect(abs(bounds.extents.y - 0.06) < 0.0001)
        #expect(abs(bounds.extents.z - 0.04) < 0.0001)
    }

    /// 掴むと約 0.15 秒で掴んでいる見た目になり、離すと戻る
    @Test func grabFadesInAndOut() async throws {
        let handle = await PanelPlacement.makeHandle()
        PanelPlacement.update(handle: handle, grabbing: true, deltaTime: 0.075)
        #expect(abs(try grab(of: handle) - 0.5) < 0.01)
        PanelPlacement.update(handle: handle, grabbing: true, deltaTime: 0.1)
        #expect(try grab(of: handle) == 1)
        PanelPlacement.update(handle: handle, grabbing: false, deltaTime: 0.075)
        #expect(abs(try grab(of: handle) - 0.5) < 0.01)
        PanelPlacement.update(handle: handle, grabbing: false, deltaTime: 1)
        #expect(try grab(of: handle) == 0)
    }

    private func grab(of handle: ModelEntity) throws -> Float {
        let material = try #require(handle.model?.materials.first as? ShaderGraphMaterial)
        guard case let .float(value) = material.getParameter(name: "Grab") else {
            Issue.record("Grab が Float ではない")
            return .nan
        }
        return value
    }
}
