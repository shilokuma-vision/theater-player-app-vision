# RealityKitContent

アプリで使う 3D の素材（USD のシーン・マテリアル）を置く Swift Package です。Xcode の visionOS アプリのテンプレートが作るものと同じ構成です。

- 素材は `Sources/RealityKitContent/RealityKitContent.rkassets/` に置きます。ビルドのときに RealityKit 用に変換され、パッケージのバンドルに入ります
- 編集は Reality Composer Pro で行います。Xcode でこのパッケージの `Package.realitycomposerpro` を開くか、`Model3D` のプレビューの「Open in Reality Composer Pro」から開きます
- アプリからは `realityKitContentBundle` を指定して読み込みます

```swift
import RealityKit
import RealityKitContent

Model3D(named: "Scene", bundle: realityKitContentBundle)
let entity = try await Entity(named: "Immersive", in: realityKitContentBundle)
```

| ファイル | 内容 |
| --- | --- |
| `Scene.usda` | ウィンドウ（`ContentView`）に出す球 |
| `Immersive.usda` | Immersive Space（`ImmersiveView`）に置く 2 つの球 |
| `Materials/GridMaterial.usda` | 球に貼るグリッドのマテリアル |
