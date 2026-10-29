//
//  main.swift
//  RKPreview
//
//  書き出した映画館を macOS の RealityKit（RealityRenderer）で描き、座席からの見た目の画像を書く。
//  アプリと同じ TheaterScene（照明の状態・座席の組み立て・マスキング）を使うので、アプリでの見え方とほぼ同じになる。
//
//    swift run -c release --package-path Tools/Theater/RKPreview RKPreview <Theater.usdz のあるフォルダ> <出力フォルダ> [視点の名前,…]
//

import AppKit
import Foundation
import Metal
import RealityKit
import TheaterScene

/// 照明の状態
enum LightingPreset: String {
    /// 開場（客電・常時灯が点いている。スクリーンは消えている）
    case preshow
    /// 上映中（客電は消え、スクリーンの映像の光で照らされる）
    case feature
    /// アプリの開場：今までの既定（客電 0.8。暗くするほど暖かい色）
    case openHouseBefore
    /// アプリの開場：新しい既定（照明を焼き付けたときより明るく、色は白）
    case openHouse
}

/// 視点（席・見る点・照明の状態）
struct View {
    let name: String
    let seat: String
    /// 見る点（映画館の座標）
    let target: SIMD3<Float>
    let preset: LightingPreset
    var horizontalFOV: Float = 80
}

let views: [View] = [
    View(name: "G17_preshow", seat: "G-17", target: [0, 4.6, -27], preset: .preshow),
    View(name: "G17_feature", seat: "G-17", target: [0, 4.6, -27], preset: .feature),
    View(name: "C9_preshow", seat: "C-9", target: [1.5, 6.5, -27], preset: .preshow, horizontalFOV: 84),
    View(name: "M30_preshow", seat: "M-30", target: [-1, 6, -27], preset: .preshow),
    View(name: "M30_feature", seat: "M-30", target: [-1, 6, -27], preset: .feature),
    View(name: "G17_left_preshow", seat: "G-17", target: [-13, 6.5, -10], preset: .preshow, horizontalFOV: 84),
    View(name: "G17_back_preshow", seat: "G-17", target: [0, 9.5, 0], preset: .preshow, horizontalFOV: 84),
    View(name: "G17_back_feature", seat: "G-17", target: [0, 9.5, 0], preset: .feature, horizontalFOV: 84),
    View(name: "G17_up_preshow", seat: "G-17", target: [0, 15, -18], preset: .preshow, horizontalFOV: 84),
    View(name: "G17_open_before", seat: "G-17", target: [0, 4.6, -27], preset: .openHouseBefore),
    View(name: "G17_open", seat: "G-17", target: [0, 4.6, -27], preset: .openHouse),
    View(name: "M30_open_before", seat: "M-30", target: [-1, 6, -27], preset: .openHouseBefore),
    View(name: "M30_open", seat: "M-30", target: [-1, 6, -27], preset: .openHouse)
]

/// アプリ（LightingDirector）と同じ式の客電：暗くするほど暖かく、1 を超えたら白のまま
func appHouse(_ level: Float) -> (house: SIMD3<Float>, emission: SIMD3<Float>) {
    let full = min(level, 1)
    let warmth = SIMD3<Float>(1, 0.82 + 0.18 * full, 0.62 + 0.38 * full)
    return (warmth * level, warmth * pow(level, 0.8))
}

@MainActor
final class Preview {
    let theater: TheaterEnvironment
    let renderer: RealityRenderer
    let width = 1600
    let height = 900
    let color: MTLTexture
    let output: RealityRenderer.CameraOutput
    let camera = PerspectiveCamera()
    var videoScreen: ModelEntity?
    var zoneColors: [SIMD3<Float>] = []

    init(folder: URL) async throws {
        theater = try await TheaterEnvironment.load(
            usdz: folder.appendingPathComponent("Theater.usdz"),
            layout: folder.appendingPathComponent("TheaterLayout.json")
        )
        renderer = try RealityRenderer()
        renderer.entities.append(theater.root)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TheaterSceneError.metalUnavailable
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TheaterSceneError.metalUnavailable
        }
        color = texture
        output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        camera.camera.near = 0.03
        camera.camera.far = 200
        renderer.entities.append(camera)
        renderer.activeCamera = camera
        renderer.cameraSettings.colorBackground = .color(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        try makeVideoScreen()
    }

    /// 上映中の確認用に、スクリーンに試しの映像（夕焼けの絵）を貼る
    private func makeVideoScreen() throws {
        let image = TestCard.make(width: 1920, height: 804)
        let texture = try TextureResource(image: image, options: .init(semantic: .color))
        var material = UnlitMaterial(texture: texture)
        material.color.tint = .white
        let frame = ScreenFrame(aspect: 1920.0 / 804.0, spec: theater.layout.screen)
        let screen = ModelEntity(mesh: try ScreenMesh.make(frame: frame, spec: theater.layout.screen), materials: [material])
        screen.isEnabled = false
        theater.model.addChild(screen)
        theater.setMasking(frame: frame, duration: 0)
        videoScreen = screen
        zoneColors = TestCard.zoneAverages(image)
    }

    func apply(_ preset: LightingPreset) {
        var values = LightingValues()
        switch preset {
        case .preshow:
            videoScreen?.isEnabled = false
            theater.screenSurface?.isEnabled = true
        case .openHouseBefore, .openHouse:
            // 新しい既定の客電は、環境変数 RK_HOUSE で変えて試せる
            let open = Float(ProcessInfo.processInfo.environment["RK_HOUSE"] ?? "") ?? 3
            let light = appHouse(preset == .openHouse ? open : 0.8)
            values.house = light.house
            values.houseEmission = light.emission
            videoScreen?.isEnabled = false
            theater.screenSurface?.isEnabled = true
        case .feature:
            values.house = .zero
            values.houseEmission = .zero
            values.zoneLeft = zoneColors[0]
            values.zoneCenter = zoneColors[1]
            values.zoneRight = zoneColors[2]
            values.screenAverage = (zoneColors[0] + zoneColors[1] + zoneColors[2]) / 3
            videoScreen?.isEnabled = true
            theater.screenSurface?.isEnabled = false
        }
        theater.lighting.update(values)
    }

    func render(_ view: View, to url: URL) throws {
        guard let seat = theater.layout.seat(id: view.seat) else {
            print("席が見つかりません: \(view.seat)")
            return
        }
        theater.sit(at: seat)
        apply(view.preset)
        let eye = seat.eye - seat.floor
        let target = view.target - seat.floor
        let aspect = Float(height) / Float(width)
        camera.camera.fieldOfViewInDegrees = 2 * atan(tan(view.horizontalFOV / 2 * .pi / 180) * aspect) * 180 / .pi
        camera.look(at: target, from: eye, relativeTo: nil)
        for frame in 0..<8 {
            let done = RenderDone()
            try renderer.updateAndRender(deltaTime: 1.0 / 60.0, cameraOutput: output) { _ in done.mark() }
            while !done.isDone {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            if frame < 7 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }
        try save(to: url)
        print("描いた: \(url.lastPathComponent)")
    }

    private func save(to url: URL) throws {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        color.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(
                  data: &bytes,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: space,
                  bitmapInfo: info
              ),
              let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return
        }
        try png.write(to: url)
    }
}

/// 描画の終わりの印（描画の完了のハンドラーは別のスレッドから呼ばれる）
final class RenderDone: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var isDone: Bool {
        lock.withLock { done }
    }

    func mark() {
        lock.withLock { done = true }
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("使い方: RKPreview <Theater.usdz のあるフォルダ> <出力フォルダ> [視点の名前,…]")
    exit(2)
}
let folder = URL(fileURLWithPath: arguments[1])
let outFolder = URL(fileURLWithPath: arguments[2])
let only = arguments.count > 3 ? Set(arguments[3].split(separator: ",").map(String.init)) : nil

Task { @MainActor in
    do {
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        let started = Date()
        let preview = try await Preview(folder: folder)
        print(String(format: "読み込み: %.2f 秒", Date().timeIntervalSince(started)))
        for view in views where only?.contains(view.name) ?? true {
            try preview.render(view, to: outFolder.appendingPathComponent("rk_\(view.name).png"))
        }
        exit(0)
    } catch {
        print("エラー: \(error)")
        exit(1)
    }
}
dispatchMain()
