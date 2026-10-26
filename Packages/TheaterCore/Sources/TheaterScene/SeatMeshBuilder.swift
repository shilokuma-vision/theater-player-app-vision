//
//  SeatMeshBuilder.swift
//  TheaterScene
//
//  座席を並べたメッシュを作る。USDZ には座席のひな形（Unit・UnitEnd・EndL × LOD0〜2）だけを入れてあり、
//  ここで単位（TheaterLayout.units）ごとにひな形を置いて、座席のまとまり（列 × ブロック）× LOD ごとに 1 つのメッシュにする。
//  - UV1（ライトマップ）は、ひな形の 0〜1 を単位のマス（アトラスのタイル）へ移す
//  - 席番号・列の文字の板は、UV0 を番号の画像のマスへ移す
//  ひな形のメッシュの名前は「部品__マテリアル」（Body__seat_fabric など）。同じマテリアルの物を 1 つの part にまとめる。
//

import Metal
import RealityKit

/// 座席のメッシュの頂点（位置・法線・UV0・UV1）
struct SeatVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv0: SIMD2<Float>
    var uv1: SIMD2<Float>
}

/// ひな形の 1 つのメッシュ（1 つのマテリアル）
struct SeatTemplatePiece {
    /// 部品（Body・SeatPlate・RowPlate）
    let part: String
    /// マテリアルの名前（seat_fabric など）
    let materialName: String
    let material: any Material
    let vertices: [SeatVertex]
    let indices: [UInt32]
}

@MainActor
public final class SeatMeshBuilder {
    private let spec: SeatTemplateSpec
    /// "Unit_LOD0" → 部品の一覧
    private var templates: [String: [SeatTemplatePiece]] = [:]
    /// マテリアルの名前 → マテリアル（part の並び順も兼ねる）
    private var materials: [(name: String, material: any Material)] = []

    /// templateRoot：USDZ の SeatTemplates のエンティティ
    public init(templateRoot: Entity, spec: SeatTemplateSpec) throws {
        self.spec = spec
        for kindEntity in templateRoot.children {
            var pieces: [SeatTemplatePiece] = []
            for child in kindEntity.children {
                pieces += try Self.pieces(of: child)
            }
            templates[kindEntity.name] = pieces
            for piece in pieces where !materials.contains(where: { $0.name == piece.materialName }) {
                materials.append((piece.materialName, piece.material))
            }
        }
        if templates.isEmpty {
            throw TheaterSceneError.templateMissing(templateRoot.name)
        }
    }

    /// ひな形の種類の一覧（確認用）
    public var templateNames: [String] {
        templates.keys.sorted()
    }

    /// 単位の並びから、1 つの LOD のメッシュのエンティティを作る
    public func makeEntity(name: String, units: [SeatUnit], lod: Int) throws -> ModelEntity {
        var vertices: [SeatVertex] = []
        var indicesByMaterial = [[UInt32]](repeating: [], count: materials.count)
        for unit in units {
            guard let pieces = templates["\(unit.kind)_LOD\(lod)"] else {
                throw TheaterSceneError.templateMissing("\(unit.kind)_LOD\(lod)")
            }
            for piece in pieces {
                let base = UInt32(vertices.count)
                vertices += piece.vertices.map { place($0, unit: unit, part: piece.part) }
                if let slot = materials.firstIndex(where: { $0.name == piece.materialName }) {
                    indicesByMaterial[slot] += piece.indices.map { $0 + base }
                }
            }
        }
        let mesh = try Self.lowLevelMesh(vertices: vertices, indicesByMaterial: indicesByMaterial)
        let entity = ModelEntity(mesh: try MeshResource(from: mesh), materials: materials.map(\.material))
        entity.name = name
        return entity
    }

    /// ひな形の頂点を単位の位置へ置き、UV1 を単位のマスへ、番号の板の UV0 を番号のマスへ移す
    private func place(_ vertex: SeatVertex, unit: SeatUnit, part: String) -> SeatVertex {
        var out = vertex
        out.position += unit.position
        let grid = Float(spec.atlasGrid)
        let tile = SIMD2<Float>(Float(unit.tile % spec.atlasGrid), Float(unit.tile / spec.atlasGrid))
        out.uv1 = (tile + spec.atlasPad + vertex.uv1 * (1 - 2 * spec.atlasPad)) / grid
        let plates = spec.plateCells
        let label: Int? = switch part {
        case "SeatPlate":
            unit.number.map { $0 - 1 }
        case "RowPlate":
            plates.rowLetterOffset + unit.rowIndex
        default:
            nil
        }
        if let label {
            out.uv0 += plates.cell(label).origin - plates.cell(0).origin
        }
        return out
    }

    // MARK: - ひな形を読む

    private static func pieces(of entity: Entity) throws -> [SeatTemplatePiece] {
        guard let model = entity.components[ModelComponent.self], let material = model.materials.first else {
            return []
        }
        let names = entity.name.components(separatedBy: "__")
        guard names.count == 2 else {
            throw TheaterSceneError.templateMissing(entity.name)
        }
        var out: [SeatTemplatePiece] = []
        for meshModel in model.mesh.contents.models {
            for part in meshModel.parts {
                out.append(try piece(part, name: names[0], materialName: names[1], material: material))
            }
        }
        return out
    }

    private static func piece(_ part: MeshResource.Part, name: String, materialName: String, material: any Material) throws
        -> SeatTemplatePiece {
        let positions = part.positions.elements
        let normals = part.normals?.elements ?? []
        let uv0 = buffer(part, named: "st") ?? []
        let uv1 = buffer(part, named: "st1") ?? []
        guard let indices = part.triangleIndices?.elements, normals.count == positions.count, uv0.count == positions.count,
              uv1.count == positions.count else {
            throw TheaterSceneError.templateMissing(name)
        }
        let vertices = positions.indices.map { index in
            SeatVertex(position: positions[index], normal: normals[index], uv0: uv0[index], uv1: uv1[index])
        }
        return SeatTemplatePiece(part: name, materialName: materialName, material: material, vertices: vertices, indices: indices)
    }

    /// USD の primvar（st・st1）を読む。RealityKit は USD の値をそのまま持っている
    private static func buffer(_ part: MeshResource.Part, named name: String) -> [SIMD2<Float>]? {
        part.buffers.first { $0.key.name == name }?.value.get(SIMD2<Float>.self)?.elements
    }

    // MARK: - LowLevelMesh

    private static func lowLevelMesh(vertices: [SeatVertex], indicesByMaterial: [[UInt32]]) throws -> LowLevelMesh {
        let stride = MemoryLayout<SeatVertex>.stride
        let attributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<SeatVertex>.offset(of: \.position) ?? 0),
            .init(semantic: .normal, format: .float3, offset: MemoryLayout<SeatVertex>.offset(of: \.normal) ?? 16),
            .init(semantic: .uv0, format: .float2, offset: MemoryLayout<SeatVertex>.offset(of: \.uv0) ?? 32),
            .init(semantic: .uv1, format: .float2, offset: MemoryLayout<SeatVertex>.offset(of: \.uv1) ?? 40)
        ]
        let indexCount = indicesByMaterial.reduce(0) { $0 + $1.count }
        let descriptor = LowLevelMesh.Descriptor(
            vertexCapacity: vertices.count,
            vertexAttributes: attributes,
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: stride)],
            indexCapacity: indexCount,
            indexType: .uint32
        )
        let mesh = try LowLevelMesh(descriptor: descriptor)
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            vertices.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        var parts: [LowLevelMesh.Part] = []
        var offset = 0
        mesh.withUnsafeMutableIndices { raw in
            let target = raw.bindMemory(to: UInt32.self)
            for (slot, indices) in indicesByMaterial.enumerated() where !indices.isEmpty {
                for (index, value) in indices.enumerated() {
                    target[offset + index] = value
                }
                parts.append(LowLevelMesh.Part(
                    indexOffset: offset * MemoryLayout<UInt32>.size,
                    indexCount: indices.count,
                    topology: .triangle,
                    materialIndex: slot,
                    bounds: bounds(of: vertices, indices: indices)
                ))
                offset += indices.count
            }
        }
        mesh.parts.replaceAll(parts)
        return mesh
    }

    private static func bounds(of vertices: [SeatVertex], indices: [UInt32]) -> BoundingBox {
        var box = BoundingBox.empty
        for index in indices {
            box.formUnion(vertices[Int(index)].position)
        }
        return box
    }
}

/// 座席のまとまりの、目からの距離で選ぶ LOD
public enum SeatLevelOfDetail {
    /// 目からまとまりの範囲までの距離（m）の境目。これより近ければ、その LOD
    public static let thresholds: [Float] = [3.2, 9.0]

    public static func level(distance: Float) -> Int {
        thresholds.firstIndex { distance < $0 } ?? thresholds.count
    }

    /// 点 point から箱（min・max）までの距離
    public static func distance(from point: SIMD3<Float>, boxMin: SIMD3<Float>, boxMax: SIMD3<Float>) -> Float {
        let clamped = simd_clamp(point, boxMin, boxMax)
        return simd_length(point - clamped)
    }
}
