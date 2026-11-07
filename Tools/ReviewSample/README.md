# ReviewSample（審査のサンプルの動画）

App Review の担当者に渡すサンプルの動画を、コードだけで作る道具です。外部の素材（映画・音楽・画像）を使わないので、権利の心配がありません（文字は macOS のシステムフォントで描きます）。
担当者への渡し方と Notes for Review は [docs/AppReview.md](../../docs/AppReview.md) にあります。

```bash
Tools/ReviewSample/make-review-sample.sh
```

- 出力は `.build/review-sample/TheaterPlayer-Sample.mov`（git には入りません。引数で変えられます）。M4 Max で 1 分半ほど、112 MB です
- 何度作っても同じ中身になります（乱数の種を決めています）

## 中身

5 分 20 秒、1920 × 1080・24 fps の H.264、48 kHz・5.1 の AAC（384 kbps）、チャプター付きの QuickTime（.mov）です。

| 始まり | チャプター | 絵 | 音 |
|---|---|---|---|
| 0:00 | Title | アプリの名前と、外部の素材を使っていないこと | 和音（D） |
| 0:08 | Countdown | 映画のリーダーのようなカウントダウン（10 から 1） | 1 秒ごとに 1 kHz（センター） |
| 0:18 | Color Bars and 1 kHz Tone | カラーバー（75 %）とグレーの階調 | 1 kHz −20 dBFS（L・R） |
| 0:30 | Speaker Check (5.1) | スピーカーの配置図。鳴っている 1 台を黄色にする | L・C・R・Rs・Ls をピンクノイズで、LFE を 50 Hz で 6 秒ずつ |
| 1:06 | Around the Theater | 配置図の上を、音の位置の点が回る | ピンクノイズが部屋を 12 秒で 1 周（2 周） |
| 1:30 | Ambient Music | 星空とオーロラのような光の帯 | 和音の進行（D・Bm・G・A）と、あちこちのスピーカーから鳴るベル |
| 4:00 | End Credits | 黒地に白い文字のエンドロール | 音楽の続き（終わりに向けて小さくする） |

- 5 分以上にしているのは、映画館の開演の流れ（ブザー・客電・幕）が 5 分以上の動画でだけ動くからです（`ShowDirector.ceremonyMinimumDuration`）
- エンドロールのチャプター（End Credits）は後半に置いています。アプリはチャプターの名前でエンドロールを見つけ、客電を少し上げます（`CreditsFinder`）
- チャプターは Nero 形式（`moov/udta/chpl`）で、書き出したあとのファイルに足しています。アプリ（FFmpeg）は読みますが、QuickTime Player などの AVFoundation の App には出ません。
  AVAssetWriter のチャプターのトラック（テキスト）は、macOS 26 で書き終えるときに「format description is invalid」で失敗したので使っていません
- 音声のチャンネルは L・R・C・LFE・Ls・Rs の順（`kAudioChannelLayoutTag_MPEG_5_1_A`）で作り、AAC の並び（C・L・R・Ls・Rs・LFE）への並べ替えは AVAssetWriter に任せています

## ファイル

| ファイル | 役割 |
|---|---|
| [Sources/Timeline.swift](Sources/Timeline.swift) | チャプターの並びと長さ、5.1 のスピーカーの位置と、音を振り分ける計算 |
| [Sources/Picture.swift](Sources/Picture.swift) | 絵（Core Graphics・Core Text） |
| [Sources/Sound.swift](Sources/Sound.swift) | 音（試験の音・ピンクノイズ・和音とベル） |
| [Sources/Chapters.swift](Sources/Chapters.swift) | チャプター（Nero 形式）を書き足す |
| [Sources/main.swift](Sources/main.swift) | AVAssetWriter で書き出す |
