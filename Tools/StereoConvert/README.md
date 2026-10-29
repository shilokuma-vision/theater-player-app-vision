# StereoConvert（2D の動画を 3D に変換する）

2D の動画の 1 コマずつの奥行きを深度推定（[Depth Anything V2](https://github.com/DepthAnything/Depth-Anything-V2) Small の Core ML 版）で求め、左右の目の絵を作って、
左右に並べた 3D の動画（フル SBS）に書き出す Mac の道具です。
出力の名前には `_SBS` を付けるので、Theater Player で開くと自動で立体になります（操作パネルの「3D」で切り替えられます）。

## 準備（モデルを取る）

モデル（約 50 MB、Apache 2.0）は git に入れません（`Models/` は `.gitignore` 済み）。
[apple/coreml-depth-anything-v2-small](https://huggingface.co/apple/coreml-depth-anything-v2-small) から、`DepthAnythingV2SmallF16.mlpackage` を `Tools/StereoConvert/Models/` に置きます。

```bash
cd Tools/StereoConvert
base=https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/DepthAnythingV2SmallF16.mlpackage
for path in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
  curl -fL --create-dirs -o "Models/DepthAnythingV2SmallF16.mlpackage/$path" "$base/$path"
done
```

## 使い方

```bash
swift run -c release --package-path Tools/StereoConvert stereo-convert ~/Movies/clip.mp4
```

`~/Movies/clip_SBS.mp4` ができます。まず `--seconds 30` で先頭だけ変換し、Vision Pro で見て強さを決めるのがおすすめです。

| オプション | 既定 | 意味 |
|---|---|---|
| `-o`, `--output <パス>` | `<名前>_SBS.mp4` | 出力先。拡張子が `.mov` なら MOV で書く |
| `--strength <割合>` | `0.03` | 立体の強さ。いちばん近い物と遠い物の、左右のずれの差（絵の幅に対する割合） |
| `--convergence <0〜1>` | `0.35` | 画面の面に見える深さ（0 が最も遠い）。これより近い物は画面から飛び出し、遠い物は奥に見える |
| `--seconds <秒>` | なし | 先頭から指定の秒数だけ変換する |
| `--h264` | HEVC | H.264 で書く（左右に並べた幅が 4096 を超えるとき、つまり 4K の元は書けない） |
| `--overwrite` | なし | 出力先にファイルがあれば上書きする |
| `--model <パス>` | `Models/DepthAnythingV2SmallF16.mlpackage` | 深度推定のモデル（`.mlpackage` か、コンパイル済みの `.mlmodelc`） |

## 仕組み

1. AVFoundation で 1 コマずつ BGRA で読む（回転の指定は、表示の向きに直してから読む）
2. コマをモデルの入力（518×392）に縮めて、相対的な深度（近いほど大きい）を得る
3. 深度を毎コマの 2〜98 % の範囲で 0〜1 にそろえる。範囲はコマをまたいでならし、奥行きがちらつかないようにする
4. 深度を元の大きさに引き伸ばし、近い物ほど左目の絵では右へ、右目の絵では左へずらす（`--convergence` より遠い物は逆向き）。
   各画素は、ずらした先の深度で元の位置をたどり直す（後ろからたどるので穴は出ない）
5. 左右に並べて HEVC で書く。音声はそのまま写す（入れ物に入らない形式なら AAC にする）

計算の部分（深度をそろえる・引き伸ばす・左右の絵を作る）は `StereoKit` にあり、`swift test --package-path Tools/StereoConvert` でテストできます。

## 目安と限界

- 速さ：Apple M4 Max で、1080p（出力 3840×1080）が毎秒 18〜35 コマ。2 時間の映画で 1〜2 時間ほど
- 読めるのは AVFoundation で開ける形式（MP4・MOV・M4V）。MKV などは先に MP4 にしてください
- HDR の動画は SDR（BT.709）で書きます
- 奥行きは推定なので、細い物・文字・ガラス・空などは誤ることがあります。物の縁の後ろに見えてくる背景は引き伸ばして埋めるので、縁が少し崩れます
- 強すぎると目が疲れます。既定から試し、物足りなければ `--strength 0.04`〜`0.05` にしてください
