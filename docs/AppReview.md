# App Store の審査に出すとき

審査に出すたびに確かめること、審査の担当者に渡すもの（サンプルの動画と Notes for Review）をまとめます。
掲載情報（EULA を含む）の反映と、App Store Connect で手入力するもの（App のプライバシーなど）は、README の「8. App Store の掲載情報」にあります。

## 審査に出すたびにすること

1. 出すビルドを決める。develop へのマージで Upload（TestFlight）に上がったビルドを、TestFlight の実機で確かめる（ファイルを開いて、映画館で再生できる）
2. デバッグの機能や、理由の申告が要る API を変えたときは、[Release のバイナリを点検する](#release-のバイナリの点検)
3. その版のソースの Release（`v<MARKETING_VERSION>`）を作る（FFmpeg の LGPL の手続き。アプリの「ライセンス」の画面がここへ案内する）

   ```bash
   scripts/publish-source-release.sh
   ```

   確かめるだけで、何も作りません。出すコミット（develop の最新の成功した Upload）・版・添付する物を確かめて表示します。
   App Store Connect で選ぶビルドが、表示された Upload の時刻に上がったものか確かめてから、`--publish` を付けて作ります（公開。誰でも見られます）。

   ```bash
   scripts/publish-source-release.sh --publish
   ```

   - 別のコミットのビルドを出すときは `--commit <コミット>`。同じ版でビルドを出し直したときは `--replace`（タグと Release を作り直す）
   - FFmpeg・dav1d の配布物は `scripts/build-ffmpeg.sh` が置いた `.build/ffmpeg/src/` から取ります（SHA-256 を確かめます）。worktree などで無いときは、`FFMPEG_BUILD_DIR=<メインのフォルダ>/.build/ffmpeg` を付けます
4. [審査のサンプル](#審査のサンプルの動画)の URL が開けるか確かめる
5. [Notes for Review](#notes-for-review) が今の版の操作と合っているか確かめ、Metadata のワークフローで反映する（`AppStore/app_info.json` の `review.notes`）
6. `Submit/App Store` のワークフローで、出すビルドを付ける（`build_number` に 3 で確かめたビルドの番号を入れる。まず dry-run で、付けるビルドを確かめる）
7. 審査に出すと決めたら、`Submit/App Store` を `submit` を true にし、`dry_run` を外して流す（App Store Connect の画面で提出してもよい）

## Release のバイナリの点検

CI の Upload と同じく、Release で Archive したバイナリで確かめます。

```bash
xcodebuild archive -project TheaterPlayer.xcodeproj -scheme TheaterPlayer -sdk xros -configuration Release -archivePath /tmp/TheaterPlayer.xcarchive CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation -skipMacroValidation
```

```bash
app=/tmp/TheaterPlayer.xcarchive/Products/Applications/TheaterPlayer.app
otool -L "$app/TheaterPlayer" | grep -i webkit
grep -a -c -i -e youtube -e '\[TheaterPlayer\]' "$app/TheaterPlayer"
nm -u "$app/TheaterPlayer" | grep -E '^_(stat|fstat|fstatat|lstat|getattrlist|getattrlistbulk|fgetattrlist|getattrlistat|statfs|statvfs|fstatfs|fstatvfs|mach_absolute_time)$'
plutil -p "$app/Info.plist" | grep -e UsageDescription -e NSAppTransportSecurity -e ITSAppUsesNonExemptEncryption
```

| 見るもの | 期待する結果 |
|---|---|
| WebKit | リンクしていない（デバッグ用の YouTube は `#if DEBUG` の中だけ） |
| `youtube`・`[TheaterPlayer]`（診断のログ） | 0 件 |
| `nm -u` の理由の申告が要る API | `stat`・`fstat`・`lstat`（File timestamp）と `mach_absolute_time`（System boot time）だけ。増えたら README の「プライバシーマニフェスト」に沿って申告を足す |
| Info.plist | 権限の文言（`…UsageDescription`）と ATS の例外が無く、`ITSAppUsesNonExemptEncryption` が `false` |

- `xcodebuild build`（archive でない）の Release には、コードカバレッジの計測（`__profc_` の記号）とソースのパスが入るので、点検には使いません
- Swift の 15 バイト以下の文字列（`-tp-diagnostics` など）は命令の中に直接入るので、`strings`・`grep` では見つかりません。消えたかは、同じ処理の長い文字列（ログの書式の `[TheaterPlayer]`）で確かめます
- Localizable.strings には、デバッグ用の YouTube の画面の文言（「YouTube を検索」など数件）が残ります。String Catalog はビルドの構成で分けられないためで、コードは入っていないので表には出ません

## 隠しモード（起動引数）

App Store に出す Release では、起動引数で動きを変える隠しの機能を残しません（ガイドライン 2.5.19）。

| 起動引数 | 使い道 | 効くビルド |
|---|---|---|
| `-tp-diagnostics` | 実機で再生の様子を調べるログ（`Diagnostics`） | Debug と、`TP_DIAGNOSTICS` を付けたビルドだけ |
| `-screenshot-demo` | App Store のスクリーンショットの撮影（`ScreenshotDemo`） | Release でも効く（撮影は Release でビルドする）。今は普段と同じライブラリを開くだけで、機能の差は無い |

撮影モードで映画館やデモのデータを出すようにするときは、`-tp-diagnostics` と同じく `#if DEBUG || SCREENSHOT_DEMO` で囲み、
撮影のビルド（`Tools/capture_screenshots.sh` の xcodebuild）にだけ `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) SCREENSHOT_DEMO'` を付けて、提出するバイナリに残さないようにします。

実機の確認で、Release に診断のログを入れるときは、次のようにビルドします（Debug は音響の処理が追いつかないため、実機の確認は Release で行います）。

```bash
xcodebuild build -project TheaterPlayer.xcodeproj -scheme TheaterPlayer -configuration Release -destination 'generic/platform=visionOS' "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) TP_DIAGNOSTICS" -derivedDataPath <リポジトリの外> -allowProvisioningUpdates -skipPackagePluginValidation -skipMacroValidation
```

```bash
xcrun devicectl device process launch --console --device <実機> jp.shilokuma.TheaterPlayer -- -tp-diagnostics
```

## 審査のサンプルの動画

審査の担当者は自分の動画を持っていないので、試せる動画を渡します（無いと 2.1「情報が足りない」で止まりやすい）。
動画は [Tools/ReviewSample](../Tools/ReviewSample/README.md) がコードだけで作ります（5 分 20 秒・5.1・チャプター付き。外部の素材を使わない）。
5 分以上なので開演の流れ（ブザー・客電・幕）が動き、スピーカーを 1 台ずつ鳴らす区切り・部屋を回る音・エンドロール（客電が少し上がる）まで一通り見られます。

### 渡し方

| 案 | よい点 | 気になる点 |
|---|---|---|
| **GitHub の Release に置き、Notes for Review に URL を書く（おすすめ）** | アプリを変えない（容量も増えない）。担当者は実機の Safari でダウンロードし、「ファイル」の「ダウンロード」から開ける。利用者と同じ道（「ファイルを選ぶ」）を試してもらえる | 担当者がダウンロードの手順を飛ばすと、2.1 で戻ってくることがある。112 MB のダウンロードが要る |
| アプリに同梱し、ライブラリに「サンプルを再生」を出す | 担当者がすぐ試せる。初めての利用者にも映画館を見せられる | アプリが 112 MB 増える（短くすると開演の流れが動かない）。画面と体験が変わるので、仕様の判断が要る |

Release に置く案で出し、2.1 で戻ってきたら同梱を考えます。置く場所は、版と関係なく同じ URL になるよう、`review-sample` という Release にしています（2026-11-08 に公開済み）。最初に作ったときのコマンドは次のとおりです。

```bash
Tools/ReviewSample/make-review-sample.sh
```

```bash
gh release create review-sample .build/review-sample/TheaterPlayer-Sample.mov -R shilokuma-vision/theater-player-app-vision --target develop --latest=false --title "Sample video for App Review" --notes "A sample video for App Review of Theater Player (5 min 20 s, 1080p H.264, 5.1 AAC, with chapters). It was generated by Tools/ReviewSample in this repository and contains no third-party content."
```

- URL は `https://github.com/shilokuma-vision/theater-player-app-vision/releases/download/review-sample/TheaterPlayer-Sample.mov` です
- 作り直したときは、`gh release upload review-sample <ファイル> --clobber -R shilokuma-vision/theater-player-app-vision` で差し替えます

## Notes for Review

App Store Connect の「App Review に関する情報」→「メモ」は、`AppStore/app_info.json` の `review.notes` に英語で書き、Metadata のワークフロー（`app-store-metadata.yml`）で反映します（4,000 字まで）。

- 書くこと：アプリの目的（手元のファイルを映画館で再生する。アカウント・データの収集・外部のサービスへの接続は無い）、サンプルの動画の URL と開き方、開演の流れ（5 分以上の動画で約 8.5 秒。「Start Now」で省ける）、操作パネル、映画館の出方、FFmpeg（LGPL）とライセンスの画面、プライバシーポリシーのリンクの場所
- 画面の名前は英語の表示（`Choose a File`・`Start Now`・`Leave the Theater` など）に合わせます。ボタンの名前や操作を変えたら、メモも直します
- サンプルの動画の URL（`review-sample` の Release）を変えたら、メモも直します
