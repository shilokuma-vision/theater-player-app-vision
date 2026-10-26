//
//  LightingState.swift
//  TheaterScene
//
//  照明の状態。映画館のすべてのマテリアル（照明を焼いた unlit の ShaderGraph）が共有する、横に並んだ数画素の画像に書く。
//  マテリアルの入力 lightState をこの画像に差し替えておけば、画像を GPU で書き換えるだけで、部屋じゅうの明るさとスクリーンの照り返しが変わる
//  （マテリアルを付け直さない）。
//

import Metal
import RealityKit

/// 照明の層ごとの明るさと、スクリーンの区画の色（リニア。1 が焼いたときの明るさ）
public struct LightingValues: Sendable, Equatable {
    /// 客電（ダウンライト・間接照明・壁を洗う光）
    public var house = SIMD3<Float>(repeating: 1)
    /// 常時灯（足元灯・袖の灯・誘導灯・舞台の縁の LED）
    public var ambient = SIMD3<Float>(repeating: 1)
    /// スクリーンの左・中央・右の区画の光の色（映像の明るさ × 照り返しの強さ）
    public var zoneLeft = SIMD3<Float>(repeating: 0)
    public var zoneCenter = SIMD3<Float>(repeating: 0)
    public var zoneRight = SIMD3<Float>(repeating: 0)
    /// 映写窓のレンズの光（映像の平均の色）
    public var screenAverage = SIMD3<Float>(repeating: 0)
    /// 客電の器具の光る面（レンズ・LED の帯）の明るさ
    public var houseEmission = SIMD3<Float>(repeating: 1)
    /// 全体の明るさ（席の移動のときの暗転など）
    public var exposure: Float = 1

    public init() {}

    /// 画像の画素の並び（TheaterLayout.lightState.texels の順）
    func texels(order: [String: Int], width: Int) -> [SIMD4<Float>] {
        var out = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: width)
        let values: [String: SIMD3<Float>] = [
            "house": house, "ambient": ambient, "zoneL": zoneLeft, "zoneC": zoneCenter, "zoneR": zoneRight,
            "screenAverage": screenAverage, "houseEmission": houseEmission, "exposure": SIMD3(repeating: exposure)
        ]
        for (name, index) in order where index < width {
            if let value = values[name] {
                out[index] = SIMD4(value, 1)
            }
        }
        return out
    }
}

/// 照明の状態の画像（LowLevelTexture）。MainActor で使う
@MainActor
public final class LightingState {
    public private(set) var values = LightingValues()
    /// マテリアルの入力 lightState に渡す画像
    public let texture: TextureResource
    private let lowLevel: LowLevelTexture
    private let spec: LightStateSpec
    private let queue: MTLCommandQueue
    /// GPU がまだ前の内容を読んでいるあいだに書き換えないよう、受け渡しの領域を 3 つ順に使う
    private let staging: [MTLBuffer]
    private var stagingIndex = 0

    public init(spec: LightStateSpec, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        let length = spec.width * MemoryLayout<SIMD4<Float16>>.stride
        guard let device, let queue = device.makeCommandQueue() else {
            throw TheaterSceneError.metalUnavailable
        }
        let staging = (0..<3).compactMap { _ in device.makeBuffer(length: length, options: .storageModeShared) }
        guard staging.count == 3 else {
            throw TheaterSceneError.metalUnavailable
        }
        let descriptor = LowLevelTexture.Descriptor(
            pixelFormat: .rgba16Float,
            width: spec.width,
            height: 1,
            textureUsage: [.shaderRead]
        )
        lowLevel = try LowLevelTexture(descriptor: descriptor)
        texture = try TextureResource(from: lowLevel)
        self.spec = spec
        self.queue = queue
        self.staging = staging
        write(values)
    }

    /// 値を変える（前と同じなら何もしない）
    public func update(_ newValues: LightingValues) {
        guard newValues != values else {
            return
        }
        write(newValues)
    }

    private func write(_ newValues: LightingValues) {
        values = newValues
        let texels = newValues.texels(order: spec.texels, width: spec.width)
        let buffer = staging[stagingIndex]
        stagingIndex = (stagingIndex + 1) % staging.count
        let pointer = buffer.contents().bindMemory(to: SIMD4<Float16>.self, capacity: spec.width)
        for (index, texel) in texels.enumerated() {
            pointer[index] = SIMD4<Float16>(texel)
        }
        guard let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
            return
        }
        let target = lowLevel.replace(using: commands)
        let rowBytes = spec.width * MemoryLayout<SIMD4<Float16>>.stride
        blit.copy(
            from: buffer,
            sourceOffset: 0,
            sourceBytesPerRow: rowBytes,
            sourceBytesPerImage: rowBytes,
            sourceSize: MTLSize(width: spec.width, height: 1, depth: 1),
            to: target,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commands.commit()
    }
}

/// 映画館の空間で起きるエラー
public enum TheaterSceneError: Error, Sendable {
    /// Metal が使えない
    case metalUnavailable
    /// アプリの中に映画館のモデル・配置が無い
    case resourceMissing(String)
    /// 座席のひな形のメッシュが読めない
    case templateMissing(String)
}
