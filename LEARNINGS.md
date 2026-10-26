# LEARNINGS（このリポジトリ固有の知見）

- RealityKit（visionOS 26 / macOS 26）：USD から読んだ MaterialX のマテリアルは `ShaderGraphMaterial` になり、Material の入力（`inputs:houseLevel` など）を `setParameter(name:value:)` で変えられる。画像の入力を `LowLevelTexture` から作った `TextureResource` に差し替えると、以後はその画像を GPU（blit）で書き換えるだけで、マテリアルを付け直さなくても描画に反映される（2026-10-27）
- RealityKit：USD から読んだメッシュの `MeshResource.Part.buffers` には primvar がそのままの値（V を反転しない）で `st`・`st1` などの名前で入っている。`LowLevelMesh` の `.uv1` に同じ値を入れると、MaterialX の `ND_texcoord_vector2`（index 1）がそれを読む（2026-10-27）
- RealityKit：無効（`isEnabled = false`）のエンティティは `visualBounds` が空になる。LOD の切り替えの範囲などは、メッシュの元の位置から自分で持つ（2026-10-27）
- Blender 5.2：`bpy.ops.uv.pack_islands` の既定（`udim_source="CLOSEST_UDIM"`）は、0〜1 の外にある島をそれぞれ近い UDIM のマスに詰めるので、メートル単位の UV を渡すと壊れる（面積 0 になる）。`udim_source="ORIGINAL_AABB"` を使い、先に全体を 0〜1 に縮める。島が多いと余白（`margin`）だけで埋まって詰められないので、小さな灯具などは島を持たせない（2026-10-27）
- Blender 5.2：スクリプトで作ってシーンにリンクしたオブジェクトを、すぐ編集モードの演算子（UV の展開など）に渡すと何もしないことがある。`bpy.context.view_layer.update()` を挟む（2026-10-27）
- Blender の閉じた部屋（壁・天井で囲んだ室内）は、ワールドの光が入らないので「形だけ確かめる」描画も真っ暗になる。形の確認は Workbench（ソリッド表示・背面カリング）で描く。背面カリングで、面の向き（RealityKit は裏を描かない）も一緒に確かめられる（2026-10-27）
- SwiftLint：ローカルパッケージや道具（`Packages/*`・`Tools/*/`）で `swift build` すると、その中の `.build` の生成ファイル（`test_entry_point.swift` など）まで lint される。`.swiftlint.yml` の `excluded` に `"**/.build"` を入れる（2026-10-27）
- Swift 6：構造体のプロパティ（`scratch.windowed`）を読みながら、同じ構造体の別のプロパティを `inout`（`&scratch.leftReal`）で渡すと、実行時に「Fatal access conflict detected」で落ちる（構造体全体への同時アクセスになる）。作業領域はクラスにする（2026-10-27）
- テストの雑音に SplitMix64 を使うとき、種を 1・2 のように近くすると、1 サンプルずれただけの（相関の強い）列になる。無相関の 2 本が要るときは種を大きく離す（2026-10-27）
