//
//  ScreenGeometry.swift
//  TheaterScene
//
//  スクリーンの映像の範囲と、マスキング（上下左右の黒い幕）の位置、映像を貼る曲面のメッシュ。
//  映像の幅が最大（21 m）を超えない範囲で高さを最大（10.5 m）に合わせる。シネスコ（2.39:1）は上下、ビスタ・16:9 は左右を締める。
//

import RealityKit

/// 映像の向き（動画に付いた回転。スマートフォンの縦の動画など）
public enum VideoRotation: Int, Sendable, CaseIterable {
    case none = 0
    case clockwise90 = 90
    case upsideDown = 180
    case counterClockwise90 = 270
}

/// 映像の範囲（スクリーンの中心からの幅・高さ）
public struct ScreenFrame: Equatable, Sendable {
    public let width: Float
    public let height: Float

    /// 縦横比 aspect（幅 ÷ 高さ）の映像を、最大の範囲に入れたときの大きさ
    public init(aspect: Float, spec: ScreenSpec) {
        let maxAspect = spec.maxWidth / spec.maxHeight
        let aspect = max(0.2, min(aspect, 4.0))
        if aspect >= maxAspect {
            width = spec.maxWidth
            height = spec.maxWidth / aspect
        } else {
            height = spec.maxHeight
            width = spec.maxHeight * aspect
        }
    }

    /// マスキングを、作った位置（最大の範囲の縁）から動かす量。上下は Y、左右は X
    public func maskingOffsets(spec: ScreenSpec) -> MaskingOffsets {
        let shrinkY = (spec.maxHeight - height) / 2
        let shrinkX = (spec.maxWidth - width) / 2
        return MaskingOffsets(top: -shrinkY, bottom: shrinkY, left: shrinkX, right: -shrinkX)
    }
}

/// マスキングの移動量（m）
public struct MaskingOffsets: Equatable, Sendable {
    public let top: Float
    public let bottom: Float
    public let left: Float
    public let right: Float
}

/// 映像を貼る曲面（スクリーンの面より少し客席側）
public enum ScreenMesh {
    /// スクリーンの面から客席側へ離す量（m）
    public static let offset: Float = 0.02

    /// 曲面のメッシュ。UV は映像の左下が (0, 0)。rotation に合わせて UV を回す
    @MainActor
    public static func make(frame: ScreenFrame, spec: ScreenSpec, rotation: VideoRotation = .none, columns: Int = 48)
        throws -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        let rows = 2
        let centerY = spec.bottom + spec.maxHeight / 2
        for row in 0...rows {
            let fractionV = Float(row) / Float(rows)
            for column in 0...columns {
                let fractionU = Float(column) / Float(columns)
                let x = (fractionU - 0.5) * frame.width
                let point = surfacePoint(x: x, y: centerY + (fractionV - 0.5) * frame.height, spec: spec)
                positions.append(point)
                normals.append(normal(x: x, spec: spec))
                uvs.append(rotate(SIMD2(fractionU, fractionV), rotation))
            }
        }
        var indices: [UInt32] = []
        let stride = UInt32(columns + 1)
        for row in 0..<UInt32(rows) {
            for column in 0..<UInt32(columns) {
                let corner = row * stride + column
                indices += [corner, corner + 1, corner + stride + 1, corner, corner + stride + 1, corner + stride]
            }
        }
        var descriptor = MeshDescriptor(name: "VideoScreen")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }

    /// スクリーンの曲面の、横位置 x（弦の上の位置）・高さ y の点（少し客席側）
    public static func surfacePoint(x: Float, y: Float, spec: ScreenSpec) -> SIMD3<Float> {
        SIMD3(x, y, spec.center.z + sag(x: x, spec: spec) + offset)
    }

    /// 曲面の、中心から横に x 離れた所が、中心より客席側へ出ている量（m）。平らな物を手前に置くときの逃げ
    public static func sag(x: Float, spec: ScreenSpec) -> Float {
        spec.radius - (spec.radius * spec.radius - x * x).squareRoot()
    }

    /// 曲面の、客席側を向いた法線
    static func normal(x: Float, spec: ScreenSpec) -> SIMD3<Float> {
        simd_normalize(SIMD3(-x, 0, (spec.radius * spec.radius - x * x).squareRoot()))
    }

    static func rotate(_ uv: SIMD2<Float>, _ rotation: VideoRotation) -> SIMD2<Float> {
        switch rotation {
        case .none:
            uv
        case .clockwise90:
            SIMD2(1 - uv.y, uv.x)
        case .upsideDown:
            SIMD2(1 - uv.x, 1 - uv.y)
        case .counterClockwise90:
            SIMD2(uv.y, 1 - uv.x)
        }
    }
}
