//
//  TheaterEnvironment.swift
//  TheaterScene
//
//  映画館の空間：USDZ（Theater.usdz）と配置（TheaterLayout.json）を読み、照明の状態・座席・マスキングをつなぐ。
//  root を RealityView の content に入れる。座る席を変えるときは root を動かして、その席の床を原点（足もと）に合わせる。
//

import Foundation
import RealityKit

/// 座席のまとまり（列 × ブロック）の LOD ごとのエンティティ
@MainActor
public struct SeatGroupEntities {
    public let name: String
    public let lods: [ModelEntity]
    public let boundsMin: SIMD3<Float>
    public let boundsMax: SIMD3<Float>
}

@MainActor
public final class TheaterEnvironment {
    /// RealityView に入れるエンティティ。席に合わせて動かす
    public let root = Entity()
    /// 映画館のモデル（root の子）
    public let model: Entity
    public let layout: TheaterLayout
    public let lighting: LightingState
    public private(set) var seatGroups: [SeatGroupEntities] = []
    /// 今の席
    public private(set) var currentSeat: Seat?
    /// マスキングの作った位置
    private var maskingRest: [String: Transform] = [:]
    /// マスキングの作った位置での範囲（x の縁。幕を閉じるとき、左右を中央まで伸ばすのに使う）
    private var maskingRestEdges: [String: ClosedRange<Float>] = [:]
    /// マスキングの行き先（最後に setMasking に渡した範囲と、幕を閉じているか）
    private var maskingPose: MaskingPose?

    private struct MaskingPose: Equatable {
        let frame: ScreenFrame
        let closed: Bool
    }

    /// 幕を閉じたとき、左右のマスキングが中央を越えて重なる幅（m。すき間から奥の映像が見えないように）
    private static let curtainOverlap: Float = 0.06
    /// 幕を閉じたとき、右のマスキングを客席側へ出す量（m。重なった所で左右がちらつかないように）
    private static let curtainLayer: Float = 0.03

    /// アプリ（bundle）の Theater.usdz と TheaterLayout.json を読む
    public static func load(bundle: Bundle = .main, subdirectory: String? = nil) async throws -> TheaterEnvironment {
        guard let usdz = bundle.url(forResource: "Theater", withExtension: "usdz", subdirectory: subdirectory) else {
            throw TheaterSceneError.resourceMissing("Theater.usdz")
        }
        guard let json = bundle.url(forResource: "TheaterLayout", withExtension: "json", subdirectory: subdirectory) else {
            throw TheaterSceneError.resourceMissing("TheaterLayout.json")
        }
        return try await load(usdz: usdz, layout: json)
    }

    public static func load(usdz: URL, layout: URL) async throws -> TheaterEnvironment {
        let model = try await Entity(contentsOf: usdz)
        let layout = try TheaterLayout.load(from: layout)
        return try await TheaterEnvironment(model: model, layout: layout)
    }

    init(model: Entity, layout: TheaterLayout) async throws {
        self.model = model
        self.layout = layout
        lighting = try LightingState(spec: layout.lightState)
        root.name = "TheaterRoot"
        root.addChild(model)
        bindLighting(model)
        try await buildSeats()
        for name in [layout.screen.masking.top, layout.screen.masking.bottom, layout.screen.masking.left, layout.screen.masking.right] {
            if let entity = model.findEntity(named: name) {
                maskingRest[name] = entity.transform
                let bounds = entity.visualBounds(relativeTo: entity.parent)
                maskingRestEdges[name] = bounds.min.x...bounds.max.x
            }
        }
    }

    // MARK: - 照明

    /// すべての照明を焼いたマテリアルの入力 lightState を、照明の状態の画像に差し替える
    public func bindLighting(_ entity: Entity) {
        if var component = entity.components[ModelComponent.self] {
            var changed = false
            component.materials = component.materials.map { material in
                guard var graph = material as? ShaderGraphMaterial, graph.parameterNames.contains("lightState") else {
                    return material
                }
                try? graph.setParameter(name: "lightState", value: .textureResource(lighting.texture))
                changed = true
                return graph
            }
            if changed {
                entity.components.set(component)
            }
        }
        for child in entity.children {
            bindLighting(child)
        }
    }

    // MARK: - 座席

    private func buildSeats() async throws {
        guard let templates = model.findEntity(named: layout.seatTemplates.entity) else {
            throw TheaterSceneError.templateMissing(layout.seatTemplates.entity)
        }
        templates.isEnabled = false
        let builder = try SeatMeshBuilder(templateRoot: templates, spec: layout.seatTemplates)
        let seatsRoot = Entity()
        seatsRoot.name = "Seats"
        model.addChild(seatsRoot)
        let grouped = Dictionary(grouping: layout.units, by: \.group)
        for name in grouped.keys.sorted() {
            guard let units = grouped[name] else {
                continue
            }
            var lods: [ModelEntity] = []
            for lod in 0..<3 {
                lods.append(try await builder.makeEntity(name: "\(name)_LOD\(lod)", units: units, lod: lod))
            }
            let groupEntity = Entity()
            groupEntity.name = name
            for (lod, entity) in lods.enumerated() {
                entity.isEnabled = lod == 2
                groupEntity.addChild(entity)
            }
            seatsRoot.addChild(groupEntity)
            // 範囲は単位の位置から（無効にしたエンティティは visualBounds が空になる）
            let positions = units.map(\.position)
            let low = positions.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
            let high = positions.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
            seatGroups.append(SeatGroupEntities(
                name: name,
                lods: lods,
                boundsMin: low + SIMD3(-0.35, 0, -0.45),
                boundsMax: high + SIMD3(0.35, 1.15, 0.4)
            ))
        }
    }

    /// 目の位置（映画館の座標）に合わせて、座席のまとまりの LOD を選ぶ
    public func updateLevelOfDetail(eye: SIMD3<Float>) {
        for group in seatGroups {
            let distance = SeatLevelOfDetail.distance(from: eye, boxMin: group.boundsMin, boxMax: group.boundsMax)
            let level = SeatLevelOfDetail.level(distance: distance)
            for (lod, entity) in group.lods.enumerated() where entity.isEnabled != (lod == level) {
                entity.isEnabled = lod == level
            }
        }
    }

    /// 席に座る：その席の床を、空間の原点（利用者の足もと）に合わせる。座席はスクリーン（-Z）を向いている
    public func sit(at seat: Seat) {
        currentSeat = seat
        root.position = -seat.floor
        updateLevelOfDetail(eye: seat.eye)
    }

    // MARK: - マスキング

    /// 映像の範囲に合わせてマスキングを動かす（行き先が今と同じなら何もしない。動かし直すと動きが始めからになり、なかなか開かない）。
    /// closed：幕を閉じる（左右のマスキングを、外側の縁はそのままに中央まで伸ばし、スクリーンを覆う。上下は映像の範囲のまま）
    public func setMasking(frame: ScreenFrame, closed: Bool = false, duration: TimeInterval = 2.5) {
        let pose = MaskingPose(frame: frame, closed: closed)
        guard pose != maskingPose else {
            return
        }
        maskingPose = pose
        let offsets = frame.maskingOffsets(spec: layout.screen)
        let names = layout.screen.masking
        let moves: [(String, SIMD3<Float>)] = [
            (names.top, SIMD3(0, offsets.top, 0)),
            (names.bottom, SIMD3(0, offsets.bottom, 0)),
            (names.left, SIMD3(offsets.left, 0, 0)),
            (names.right, SIMD3(offsets.right, 0, 0))
        ]
        for (name, delta) in moves {
            guard let entity = model.findEntity(named: name), let rest = maskingRest[name] else {
                continue
            }
            var transform = rest
            transform.translation += delta
            if closed, name == names.left || name == names.right, let edges = maskingRestEdges[name] {
                let isLeft = name == names.left
                // 左の幕の内側の縁は右端（max）、右の幕は左端（min）
                let stretch = HorizontalStretch(
                    inner: isLeft ? edges.upperBound : edges.lowerBound,
                    outer: isLeft ? edges.lowerBound : edges.upperBound,
                    origin: rest.translation.x,
                    toInner: isLeft ? Self.curtainOverlap : -Self.curtainOverlap,
                    toOuter: isLeft ? edges.lowerBound : edges.upperBound
                )
                transform.scale.x *= stretch.scale
                transform.translation.x = stretch.origin
                transform.translation.z += isLeft ? 0 : Self.curtainLayer
            }
            if duration > 0 {
                entity.move(to: transform, relativeTo: entity.parent, duration: duration, timingFunction: .easeInOut)
            } else {
                entity.transform = transform
            }
        }
    }

    /// 映像を出していないときのスクリーンの面（映像を出すあいだは隠す）
    public var screenSurface: Entity? {
        model.findEntity(named: layout.screen.surface)
    }
}
