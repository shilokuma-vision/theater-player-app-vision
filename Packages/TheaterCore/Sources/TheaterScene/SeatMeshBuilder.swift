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
struct SeatVertex: Sendable {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv0: SIMD2<Float>
    var uv1: SIMD2<Float>
}

/// ひな形の 1 つのメッシュ（1 つのマテリアル）。MainActor の外で並べるので、マテリアルは番号で持つ
struct SeatTemplatePiece: Sendable {
    /// 部品（Body・SeatPlate・RowPlate）
    let part: String
    /// マテリアルの番号（SeatMeshBuilder の materials の並び）
    let materialIndex: Int
    let vertices: [SeatVertex]
    let indices: [UInt32]
}

/// 並べた座席の形（LowLevelMesh に入れる前の頂点と、マテリアルごとの三角形・範囲）
struct SeatMeshData: Sendable {
    var vertices: [SeatVertex] = []
    var indicesByMaterial: [[UInt32]]
    var bounds: [BoundingBox] = []
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
                pieces += try self.pieces(of: child)
            }
            templates[kindEntity.name] = pieces
        }
        if templates.isEmpty {
            throw TheaterSceneError.templateMissing(templateRoot.name)
        }
    }

    /// ひな形の種類の一覧（確認用）
    public var templateNames: [String] {
        templates.keys.sorted()
    }

    /// 単位の並びから、1 つの LOD のメッシュのエンティティを作る。
    /// 頂点を並べるのは MainActor の外で行う（全部で数十万の三角形があり、映画館を開くときに画面が止まるため）
    public func makeEntity(name: String, units: [SeatUnit], lod: Int) async throws -> ModelEntity {
        let data = try await Self.arrange(units: units, lod: lod, templates: templates, spec: spec, materialCount: materials.count)
        let mesh = try Self.lowLevelMesh(data)
        let entity = ModelEntity(mesh: try await MeshResource(from: mesh), materials: materials.map(\.material))
        entity.name = name
        return entity
    }

    /// ひな形を単位の位置に並べて、1 つのメッシュの頂点と、マテリアルごとの三角形・範囲にする
    @concurrent
    nonisolated private static func arrange(
        units: [SeatUnit],
        lod: Int,
        templates: [String: [SeatTemplatePiece]],
        spec: SeatTemplateSpec,
        materialCount: Int
    ) async throws -> SeatMeshData {
        var data = SeatMeshData(indicesByMaterial: [[UInt32]](repeating: [], count: materialCount))
        for unit in units {
            guard let pieces = templates["\(unit.kind)_LOD\(lod)"] else {
                throw TheaterSceneError.templateMissing("\(unit.kind)_LOD\(lod)")
            }
            for piece in pieces {
                let base = UInt32(data.vertices.count)
                data.vertices += piece.vertices.map { place($0, unit: unit, part: piece.part, spec: spec) }
                data.indicesByMaterial[piece.materialIndex] += piece.indices.map { $0 + base }
            }
        }
        data.bounds = data.indicesByMaterial.map { bounds(of: data.vertices, indices: $0) }
        return data
    }

    /// ひな形の頂点を単位の位置へ置き、UV1 を単位のマスへ、番号の板の UV0 を番号のマスへ移す
    nonisolated private static func place(_ vertex: SeatVertex, unit: SeatUnit, part: String, spec: SeatTemplateSpec) -> SeatVertex {
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

    private func pieces(of entity: Entity) throws -> [SeatTemplatePiece] {
        guard let model = entity.components[ModelComponent.self], let material = model.materials.first else {
            return []
        }
        let names = entity.name.components(separatedBy: "__")
        guard names.count == 2 else {
            throw TheaterSceneError.templateMissing(entity.name)
        }
        let materialIndex = index(ofMaterial: names[1], material: material)
        var out: [SeatTemplatePiece] = []
        for meshModel in model.mesh.contents.models {
            for part in meshModel.parts {
                out.append(try Self.piece(part, name: names[0], materialIndex: materialIndex))
            }
        }
        return out
    }

    /// マテリアルの番号（初めて出てきた名前なら足す）
    private func index(ofMaterial name: String, material: any Material) -> Int {
        if let index = materials.firstIndex(where: { $0.name == name }) {
            return index
        }
        materials.append((name, material))
        return materials.count - 1
    }

    private static func piece(_ part: MeshResource.Part, name: String, materialIndex: Int) throws -> SeatTemplatePiece {
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
        return SeatTemplatePiece(part: name, materialIndex: materialIndex, vertices: vertices, indices: indices)
    }

    /// USD の primvar（st・st1）を読む。RealityKit は USD の値をそのまま持っている
    private static func buffer(_ part: MeshResource.Part, named name: String) -> [SIMD2<Float>]? {
        part.buffers.first { $0.key.name == name }?.value.get(SIMD2<Float>.self)?.elements
    }

    // MARK: - LowLevelMesh

    /// 並べた形を LowLevelMesh に写す（MainActor。写すだけにして軽くする）
    private static func lowLevelMesh(_ data: SeatMeshData) throws -> LowLevelMesh {
        let stride = MemoryLayout<SeatVertex>.stride
        let attributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<SeatVertex>.offset(of: \.position) ?? 0),
            .init(semantic: .normal, format: .float3, offset: MemoryLayout<SeatVertex>.offset(of: \.normal) ?? 16),
            .init(semantic: .uv0, format: .float2, offset: MemoryLayout<SeatVertex>.offset(of: \.uv0) ?? 32),
            .init(semantic: .uv1, format: .float2, offset: MemoryLayout<SeatVertex>.offset(of: \.uv1) ?? 40)
        ]
        let indexCount = data.indicesByMaterial.reduce(0) { $0 + $1.count }
        let descriptor = LowLevelMesh.Descriptor(
            vertexCapacity: data.vertices.count,
            vertexAttributes: attributes,
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: stride)],
            indexCapacity: indexCount,
            indexType: .uint32
        )
        let mesh = try LowLevelMesh(descriptor: descriptor)
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            data.vertices.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        var parts: [LowLevelMesh.Part] = []
        var offset = 0
        mesh.withUnsafeMutableIndices { raw in
            for (slot, indices) in data.indicesByMaterial.enumerated() where !indices.isEmpty {
                let byteOffset = offset * MemoryLayout<UInt32>.size
                indices.withUnsafeBytes { UnsafeMutableRawBufferPointer(rebasing: raw[byteOffset...]).copyMemory(from: $0) }
                parts.append(LowLevelMesh.Part(
                    indexOffset: byteOffset,
                    indexCount: indices.count,
                    topology: .triangle,
                    materialIndex: slot,
                    bounds: data.bounds[slot]
                ))
                offset += indices.count
            }
        }
        mesh.parts.replaceAll(parts)
        return mesh
    }

    nonisolated private static func bounds(of vertices: [SeatVertex], indices: [UInt32]) -> BoundingBox {
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
