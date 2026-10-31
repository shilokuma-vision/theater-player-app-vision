# Theater Player

Apple Vision Pro で、映画館の空間に入って手元の動画・音楽を再生し、画像・PDF を映すアプリです。

- **VLC と同じくらい幅広い形式**：VLC が内部で使っている FFmpeg でファイルを開くので、MKV・MP4・MOV・AVI・WMV・FLV・WebM・TS・M2TS・VOB・OGG などの動画と、
  AAC・AC-3・E-AC-3・DTS・TrueHD・FLAC・ALAC・MP3・Opus・Vorbis・WMA・APE・DSD・WAV などの音声を再生できます。H.264・HEVC（HDR を含む）・ProRes などは VideoToolbox（ハードウェア）でデコードします。
  字幕（SRT・ASS・WebVTT・PGS・DVD など）、音声・字幕のトラックの切り替え、チャプター、シーク、再生の速さ、音・字幕のずれの調整、続きからの再生に対応します
- **Blender で作った映画館**：442 席のスタジアム形式の劇場（曲面スクリーン・マスキング・木のフィンと吸音パネル・浮き天井のダウンライトと間接照明・足元灯・誘導灯・サラウンドスピーカー）。
  照明は Cycles で層ごとに焼き付け、客電の明るさと、映像の色によるスクリーンの照り返しをアプリで変えます（[Tools/Theater](Tools/Theater/README.md)）
- **映画館の空間オーディオ**：スクリーンの裏の L / C / R、サブウーファー、側壁・後方・天井のサラウンドの位置に、RealityKit の空間オーディオの音源を置いて鳴らします。
  5.1・7.1・7.1.4 はそのまま、ステレオは映画館向けに広げます。低音はサブウーファーへ集め、低音の量・低音の残響・体感の低音（倍音）を調整できます
- **3D（立体視）**：左右・上下に並べた 3D の動画（SBS・TAB。フル・ハーフ）と、iPhone・Vision Pro で撮った空間ビデオ（MV-HEVC）を、スクリーンに立体で映します。
  並べ方は入れ物の情報（MKV の StereoMode・MOV の vexu）かファイル名の印（`_SBS`・`_TAB` など）で見分け、操作パネルの「3D」でも選べます。
  手元の 2D の動画は、Mac の道具で深度推定を使って 3D に変換できます（[Tools/StereoConvert](Tools/StereoConvert/README.md)）
- **画像と PDF**：PNG・JPEG・HEIC・GIF・WebP などの画像と PDF も、スクリーンに映して見られます（縦横比に合わせてマスキングが動き、
  画像の色で部屋が照らされます）。PDF は操作パネルでページを送れ、最近の一覧から開くと前回のページから見られます
- **部屋の明るさと座る席**：開場（再生していないとき）は明るく、再生を始めると客電がゆっくり落ち、止めると戻ります。座席表から好きな席に移れます
- **上映の進行**：動画を開いて頭から再生すると、開演のブザーが場内の天井から鳴り、客電が半分まで落ちて、閉じた幕（左右のマスキング）が開いてから本編が始まります（約 8.5 秒。操作パネルの「すぐに始める」で省けます）。
  エンドロールでは客電を少し上げ、終わるとゆっくり開場の明るさに戻します。エンドロールは、チャプターの名前（Credits・エンドロール など）か、長い作品の終わり近くで黒地に文字の画面が続いたところで見つけます。
  続きから再生するとき・5 分より短い動画では、ブザーと幕は省きます。操作パネルの「部屋の明るさ」で切にできます
- **動かせる操作パネル**：手元の操作パネルは、下のつまみをつまんで好きな位置へ動かせます（位置は覚えます）
- **パネルを出さずに操作**：コントロールセンター・AirPods・Siri・メディアキーから、再生・一時停止・スキップ・シーク・チャプターの移動ができます（再生中の題名・位置・ジャケットはコントロールセンターに出ます）。
  畳んだ操作パネルは、スクリーンを見てつまむと出ます
  - Bluetooth のキーボード：スペース＝再生・一時停止、← →＝10 秒戻る・進む、↑ ↓＝音量、N・P＝次・前のチャプター、Return＝操作パネルを出す
  - ゲームコントローラー：A＝再生・一時停止、B＝操作パネルを出す、十字キーの左右＝10 秒戻る・進む、上下＝音量、L1・R1＝前・次のチャプター
  - Siri・ショートカットの App：「Theater Player を一時停止」「Theater Player で 30 秒戻して」、英語では「Pause Theater Player」「Skip back 30 seconds in Theater Player」など（一時停止・再生・戻す・進む・次／前のチャプター）

## ファイルの入れ方

- **「ファイル」App の Theater Player のフォルダ**：「ファイル」App の「この Apple Vision Pro内」（On My Apple Vision Pro）に「Theater Player」のフォルダがあります（アプリのフォルダを共有しています。`UIFileSharingEnabled`）。
  ここに入れた動画・音楽・画像・PDF は、ライブラリの「ファイルを選ぶ」でこのフォルダを開いて選べます。
  フォルダは空だと「ファイル」App に出ないので、空なら起動したときに案内（`使い方.txt`。英語のときは `How to Use.txt`）を置きます（消してもかまいません。ほかのファイルがあれば置き直しません）
- **Mac から送る**：iCloud Drive に入れる・AirDrop で送る・「ファイル」App の「サーバへ接続」で Mac の共有フォルダを開く、のどれかで Vision Pro に届け、「ファイル」App で Theater Player のフォルダへ移します。
  Finder のファイル共有（ケーブルでつないだ端末の「ファイル」タブ）は、Apple の案内では iPhone・iPad が対象で、Vision Pro は載っていません
- **コピーせずに開く**：iCloud Drive・外部ストレージ・ファイルサーバのファイルも、「ファイルを選ぶ」でその場所のまま開けます（`LSSupportsOpeningDocumentsInPlace`）。最近の一覧から開き直せます
- Theater Player のフォルダの中身は、ほかのアプリの書類と同じく端末のバックアップに含まれます。大きな動画を入れたままにすると、iCloud バックアップの容量を使います

## Environment

- Xcode 26.6
- visionOS 26.0 以上
- FFmpeg 9.0.2（LGPL の構成。`scripts/build-ffmpeg.sh` でソースから作る。下の「開発の準備」）
- Blender 5.2（映画館のモデルを作り直すときだけ。[Tools/Theater](Tools/Theater/README.md)）
- Swift 6（Swift 6 言語モード / Strict Concurrency）
- SwiftUI / RealityKit / Swift Testing / XCTest（UI テスト）
- SwiftLint 0.65.1（Build Tool Plugin。バイナリだけを配布する [SwiftLintPlugins](https://github.com/SimplyDanny/SwiftLintPlugins) 経由）
- visionOS の Simulator ランタイム（約 7 GB）。Xcode の Settings → Components か、`xcodebuild -downloadPlatform visionOS` で入れます

## Status

<div style="margin:0px;padding:0px;">
  <table width="98%" style="border-collapse: collapse;border:2px double #000080;text-align:center;margin:auto;">
    <tbody>
      <tr>
        <td style="border:2px double #000080;">branch \ workflow</td>
        <td style="border:2px double #000080;">Build</td>
        <td style="border:2px double #000080;">Archive</td>
        <td style="border:2px double #000080;">Upload</td>
      </tr>
      <tr>
        <td style="border:2px double #000080;text-align:left;">main</td>
        <td style="border:2px double #000080;text-align:center;">
          <a href="https://github.com/shilokuma-vision/theater-player-app-vision/actions/workflows/build.yml?query=branch%3Amain">
            <img src="https://github.com/shilokuma-vision/theater-player-app-vision/actions/workflows/build.yml/badge.svg?branch=main" alt="Build">
          </a>
        </td>
        <td style="border:2px double #000080;text-align:center;">
          <a href="https://github.com/shilokuma-vision/theater-player-app-vision/actions/workflows/archive.yml?query=branch%3Amain">
            <img src="https://github.com/shilokuma-vision/theater-player-app-vision/actions/workflows/archive.yml/badge.svg?branch=main" alt="Archive">
          </a>
        </td>
        <td style="border:2px double #000080;text-align:center;">
        </td>
      </tr>
      <tr>
        <td style="border:2px double #000080;text-align:left;">develop</td>
        <td style="border:2px double #000080;text-align:center;">
          <a href="https://github.com/shilokuma-vision/theater-player-app-vision/actions/workflows/build.yml?query=branch%3Adevelop">
            <img src="https://github.com/shilokuma-vision/theater-player-app-vision/actions/workflows/build.yml/badge.svg?branch=develop" alt="Build">
          </a>
        </td>
        <td style="border:2px double #000080;text-align:center;">
        </td>
        <td style="border:2px double #000080;text-align:center;">
          <a href="https://github.com/shilokuma-vision/theater-player-app-vision/actions/workflows/upload.yml?query=branch%3Adevelop">
            <img src="https://github.com/shilokuma-vision/theater-player-app-vision/actions/workflows/upload.yml/badge.svg?branch=develop" alt="Upload">
          </a>
        </td>
      </tr>
    </tbody>
  </table>
</div>

## 開発の準備（FFmpeg）

FFmpeg（と AV1 の dav1d）は、リポジトリに入れずにソースから作ります。clone したら最初に一度だけ実行してください（M4 Max で数分）。

```bash
scripts/build-ffmpeg.sh
```

- 公式の配布物（ffmpeg.org・videolan.org）を取得し、SHA-256 を確かめてから、visionOS の実機（xros）と Simulator（xrsimulator）向けにビルドします。Simulator の分だけなら `scripts/build-ffmpeg.sh xrsimulator`
- FFmpeg のソースには `scripts/ffmpeg/patches/` のパッチを当てます（visionOS に無い OpenGL ES の指定を Metal に替えるなど。中身は各パッチの先頭の説明）
- できあがるのは `Packages/TheaterMedia/Vendor/FFmpeg.xcframework`（git には入りません）。これが無いと Xcode がパッケージを読めません
- FFmpeg は LGPL 2.1 以降の構成です（GPL・nonfree のコンポーネントは有効にしません）。dav1d は BSD 2-Clause です
- CI ではキャッシュし、スクリプト・パッチ・Xcode・Deployment Target が変わったときだけ作り直します
- セキュリティソフトがスクリプトの直接の実行を止める（`zsh: killed`）Mac では、`bash scripts/build-ffmpeg.sh` で実行します
- dav1d のビルドには Python の仮想環境に meson・ninja を入れます（pip を使います）。pip が使えないときは `FFMPEG_WITHOUT_DAV1D=1` を付けると dav1d を入れずに作れます（AV1 は VideoToolbox で扱える端末でだけ再生できます）

## リポジトリの運用（テンプレートから引き継いだもの）

### 1. リポジトリを作成する

GitHub の「Use this template」からリポジトリを作成し、clone します。

### 2. プロジェクト名を変更する

`TheaterPlayer` を新しいアプリ名に一括変更するスクリプトを用意しています。
ディレクトリ・`.xcodeproj`・スキーム・ソース内の識別子・README のバッジ URL をまとめて置換し、GitHub リポジトリの Discussions を有効にします。

```bash
scripts/rename.sh MyApp
```

- アプリ名は英字で始まる英数字のみです（Swift のモジュール名になります）
- README のバッジ URL と Discussions の有効化に使うリポジトリ名は `origin` から推定します。別のものを使う場合は第 2 引数で `owner/repo` を渡します
- 作業ツリーがクリーンな状態で実行し、実行後に `git diff` で差分を確認してコミットしてください
- テストの `@testable import <アプリ名>` は、置き換えたあとに SwiftLint の `sorted_imports` に合う順へ並べ直します
- テンプレートから作成したリポジトリには Discussions の設定が引き継がれず、無効のままになります（ralph-loop はゴールを Discussion で受け取ります）。スクリプトは `gh repo edit --enable-discussions` で有効にするため、`gh` で認証済みで、リポジトリの管理者権限が必要です
- Discussions を有効にできなかったときは、リネームは止めずに警告と手順を表示します。表示された手順で有効にしてください

### 3. 署名情報を設定する

署名情報やバージョンは pbxproj ではなく [Configs/Project.xcconfig](Configs/Project.xcconfig) に集約しています。
リポジトリ作成後、まず以下を書き換えてください。

| 設定 | 内容 |
|---|---|
| `DEVELOPMENT_TEAM` | Apple Developer Program の Team ID |
| `APP_BUNDLE_IDENTIFIER` | アプリ本体の Bundle Identifier。テストターゲットは `.Tests` / `.UITests` を付けて自動で派生します |
| `MARKETING_VERSION` | アプリのバージョン。ビルド番号（`CURRENT_PROJECT_VERSION`）は Upload のときに App Store Connect の最新ビルドを見て Xcode が自動で増やすため、手で上げる必要はありません |
| `XROS_DEPLOYMENT_TARGET` | 最低サポート OS。変えるときは [Packages/RealityKitContent/Package.swift](Packages/RealityKitContent/Package.swift) の `platforms` も揃えます |

### 4. GitHub Secrets を設定する

Archive / Upload ワークフローは App Store Connect API Key で認証します。
リポジトリ（または Organization）の Settings → Secrets and variables → Actions に以下を登録してください。

| Secret | 内容 |
|---|---|
| `EXPORT_OPTIONS` | `ExportOptions.plist` の内容。[docs/ExportOptions.sample.plist](docs/ExportOptions.sample.plist) の `teamID` を書き換えて、ファイルの中身をそのまま登録します |
| `APPLE_API_KEY_BASE64` | App Store Connect の API Key（`AuthKey_XXXXXXXXXX.p8`）を `base64 -i AuthKey_XXXXXXXXXX.p8` でエンコードした文字列 |
| `APPLE_API_KEY_ID` | API Key の Key ID |
| `APPLE_API_ISSUER_ID` | API Key の Issuer ID |

API Key は App Store Connect の「ユーザとアクセス → 統合 → App Store Connect API」で、App Manager 以上の権限で発行します。
App Store の掲載情報の反映で使う、審査の連絡先の Secrets（任意）は「8. App Store の掲載情報」を参照してください。

### 5. App Store Connect にアプリを作成する

Bundle ID・証明書・プロビジョニングプロファイルは、Export のときに API Key で自動的に作成されます（`-allowProvisioningUpdates`）。
App Store Connect でのアプリ作成だけは API で行えないため、Web 画面で行います。プラットフォームは visionOS を選びます。

アプリを作らずに `develop` へ push しても問題ありません。Upload ワークフローがアップロードの前にアプリの有無を確認し（[.github/scripts/check-app-store-app.rb](.github/scripts/check-app-store-app.rb)）、アプリが無ければ「新規アプリ」画面に入力する値（名前・バンドル ID・SKU など）を Job Summary に表示して止まります。表示された値でアプリを作成してから、ワークフローを再実行してください。

SKU は Bundle ID と同じ値にします。SKU はユーザーには見えない社内用の ID で、後から変更できないため、迷わないようにルールを固定しています。

#### TestFlight の内部テスター

Upload ワークフローは、アップロードの前に TestFlight の内部テストグループ「Internal Testers」を作り、変数 `TESTFLIGHT_INTERNAL_TESTERS` のメールアドレスを内部テスターに追加します（[.github/scripts/ensure-internal-testers.rb](.github/scripts/ensure-internal-testers.rb)）。グループは「すべてのビルドへのアクセス」を有効にして作るため、以降のビルドは処理が終わりしだい自動で配信されます。2 回目以降の Upload では確認だけで何もしません。

| 変数 | 内容 |
|---|---|
| `TESTFLIGHT_INTERNAL_TESTERS` | 内部テスターにするメールアドレス。複数のときはカンマ区切り。Organization の変数に登録しておくと、テンプレートから作ったリポジトリすべてで使われます。空なら何もしません |

- 内部テスターになれるのは App Store Connect のユーザー（「ユーザとアクセス」に登録されているメンバー）だけです
- テスターの追加に失敗してもアップロードは止めません。失敗したメールアドレスは Job Summary に表示されます
- グループの作成とテスターの追加には、API Key が App Manager 以上の権限である必要があります

### 6. ブランチ運用と CI

| ブランチ | Build（ビルド + テスト + SwiftLint） | Archive（IPA Export） | Upload（App Store Connect） |
|---|:-:|:-:|:-:|
| `main` | ✅ | ✅ | |
| `develop` | ✅ | | ✅ |
| `release/**` | ✅ | | ✅ |
| その他の作業ブランチ | ✅（Unit テストのみ） | | |
| Pull Request の作成時（opened / reopened / ready_for_review） | ✅ | | |
| Fork からの Pull Request | ✅ | | |

- テストは最新の visionOS ランタイムの Apple Vision Pro の Simulator で実行します。ランナーのイメージに visionOS のランタイムが無ければ、選んだ Xcode に合うものをダウンロードします
- Upload は Archive → IPA Export を含むため、`develop` / `release/**` では Archive を別途実行しません
- Archive / Upload は Actions タブから手動でも実行できます（Run workflow）。作業ブランチを TestFlight で確認したいときは、Upload を手動実行してそのブランチを選びます
- リポジトリ変数（Settings → Secrets and variables → Actions → Variables）に `ENABLE_DELIVERY=false` を設定すると Upload をスキップします（Archive は App Store Connect にアプリが無くても通るため止めません）。テンプレートリポジトリ自身はこの設定でアップロードを止めています。テンプレートから作成したリポジトリには引き継がれないため、何もしなければ従来どおり実行されます
- ドキュメントだけの変更（`**/*.md`、`docs/**`）では Build を実行しません。Upload（`develop` / `release/**` への push）と Archive（`main` への push）は、ドキュメントだけの変更でも実行します
- 作業ブランチへの push では、時間のかかる UI テスト（`<プロジェクト名>UITests`）を省いて Unit テストだけ実行します。UI テストは Pull Request の作成時と `main` / `develop` / `release/**` への push で実行します。Fork からの Pull Request は push で実行されないため、更新（synchronize）を含むすべてのイベントで UI テストまで実行します
- Xcode のバージョンは [.github/workflows/_build.yml](.github/workflows/_build.yml) と [.github/workflows/_archive.yml](.github/workflows/_archive.yml) の `xcode-version` で固定しています。Environment の更新時はあわせて変更してください

### 7. PR 本文のスクリーンショット

UI の見た目が変わる変更では、Before / After のスクリーンショットを PR 本文に添付します。

- visionOS の Simulator のスクリーンショットは `xcrun simctl io <UDID> screenshot <ファイル>` で撮れます（Apple Vision Pro の Simulator では 3840x2160）
- 画像は GitHub の添付ファイルとしてアップロードします。git の履歴やブランチには含まれず、マージ後も表示され続けます
  - ブラウザで PR を作る場合は、本文の入力欄に画像をドラッグ & ドロップします
  - CLI（エージェントを含む）では `gh` の `--attach`（gh v2.99.0 以上）を使います。本文に Markdown の表と `![Before](./before.png)` の形でローカルのパスを書き、同じファイルを `--attach` で渡すと、gh がその場でアップロード先の URL に書き換えます
  - HTML の `<img src="./before.png">` や `<table>` の中のパスは書き換わりません。表は Markdown で書き、幅をそろえたいときは作成後に `<img width="300">` へ置き換えます（下の例）
- アップロードした画像は削除できません。個人情報やトークンなどが写っていないか確認してから添付してください
- Before / After は表で横に並べ、同一条件（同じ端末・OS・外観モード・データ状態）で撮影します
- 影響する画面が複数ある場合は画面ごとに用意します。新規画面で Before が無い場合は「なし」と書きます

```bash
# body.md の表に ![Before](./before.png) と ![After](./after.png) を書いておく
gh pr create --title "..." --body-file body.md --assignee @me \
  --attach ./before.png --attach ./after.png

# 本文の画像を幅 300 の <img> に置き換える（本文を取得できたときだけ更新する）
body=$(gh pr view <番号> --json body -q .body) &&
  printf '%s\n' "$body" \
  | perl -pe 's{!\[([^\]]*)\]\((https://github\.com/user-attachments/assets/[^)\s]+)\)}{<img src="$2" alt="$1" width="300">}g' \
  | gh pr edit <番号> --body-file -
```

### 8. App Store の掲載情報（スクリーンショット・説明文・App 情報）

App Store のプロダクトページに載せるものは、`AppStore/` の JSON を元ネタにして、手動実行のワークフローで App Store Connect に反映します。
反映先は visionOS の「編集できる状態のバージョン」だけで、審査中・配信済みのバージョンには触りません。
どのワークフローも、リポジトリ変数 `ENABLE_DELIVERY=false` のリポジトリ（テンプレート自身など）では反映しません。

| ワークフロー | 反映するもの | 元ネタ | ランナー |
|---|---|---|---|
| `Screenshots/App Store` | スクリーンショット（Apple Vision Pro × 各言語） | `AppStore/screenshots.json` / `AppStore/languages.json` / `AppStore/app.json` | 撮影だけ macOS、反映は ubuntu |
| `Metadata/App Store` | 名前・サブタイトル・説明文・キーワード・プロモーションテキスト・最新情報・URL・プライバシーポリシーの URL・著作権、カテゴリ・コンテンツの権利・年齢制限・App Review に関する情報・価格と配信状況（既定は dry-run） | `AppStore/metadata/*.json` / `AppStore/app_info.json` | ubuntu |
| `Verify/App Store metadata` | PR で、文字数の上限・App 情報の書き方・撮影設定・撮影モードの Scene との対応を検査する | `AppStore/**` | ubuntu |

iOS 版にあるプロダクトページのヘッダーと検索結果のクリエイティブアセットは、iOS / iPadOS の App Store にだけ出るものなので、このテンプレートには入れていません。

**スクリーンショット**

- 撮影はアプリの撮影モード（[TheaterPlayer/Screenshot/ScreenshotDemo.swift](TheaterPlayer/Screenshot/ScreenshotDemo.swift)）で行います。`Tools/capture_screenshots.sh` が `-screenshot-demo -screenshot-scene <名前>` と言語を起動引数で渡し、アプリはデモデータで目的の画面を開きます
- 画面を足すときは、`ScreenshotDemo.Scene` に case を足し、`TheaterPlayer.swift` の `rootView` で開く画面を返し、`AppStore/screenshots.json` の `scenes` に同じ名前を足します（1 表示サイズにつき 10 枚まで）
- 表示サイズは Apple Vision Pro（`APP_APPLE_VISION_PRO`、3840x2160）の 1 つだけです。Simulator の「Apple Vision Pro」がこの寸法で撮れます
- 撮れるのは起動直後のウィンドウ（`WindowGroup`）で、Simulator の部屋の中に浮かんだ状態で写ります。Immersive Space の様子を載せたいときは、Xcode の Simulator で撮った画像を App Store Connect に直接上げます
- 撮るのはリリースのときだけです。`release/**` ブランチを選んで手動実行します（それ以外のブランチでは止まります）
- macOS ランナーの枠を開発のビルドと取り合わないよう、撮影は 1 本ずつ流し、App Store Connect への反映は ubuntu で行います
- 手元で撮るなら `Tools/capture_screenshots.sh APP_APPLE_VISION_PRO ja`（出力は `build/screenshots/`）

**名前・説明文・最新情報**

- `AppStore/metadata/<言語>.json` と `shared.json` に書きます。テンプレートの仮の文言（`TODO:`）が残っているあいだは反映できません
- 「このバージョンの最新情報」は `whatsNew` に `{"version": "1.1.0", "text": "…"}` の形で書きます。`version` が反映先のバージョンと一致するときだけ書き込むので、リリースごとに両方を書き換えます（最初のバージョンには最新情報の欄がありません）
- 名前（`name`）・サブタイトル（`subtitle`）も言語ごとの JSON に書きます（どちらも 30 字まで）。App Store Connect では「App 情報」の項目で、説明文とは別の場所（`appInfoLocalizations`）に書き込みます。アプリを作ったときの言語（日本語）以外は、App Store Connect に App 情報の言語が無いので、`missing_locales` を `create` にして追加します。追加するには `name` が要ります
- `shared.json` の `privacyPolicyUrl`（プライバシーポリシーの URL。すべてのアプリで必須）は全言語に、`copyright`（著作権。既定は `© 2026 Takumi Muraishi`）はバージョンに書き込みます。shilokuma のアプリのプライバシーポリシーは [shilokuma-inc/shilokuma-web](https://github.com/shilokuma-inc/shilokuma-web) の `privacy/apps.json` にアプリを足して `https://shilokuma.jp/privacy/<slug>/` に置きます

**App 情報・審査の情報・価格と配信状況**

- `AppStore/app_info.json` に書き、`Metadata/App Store` が説明文の後に続けて反映します（`Tools/upload_app_info.py`）
- App 情報・年齢制限・価格・配信状況はプラットフォームによらずアプリに 1 つです。visionOS だけのアプリでも、iOS のアプリと同じ値の書き方をします（App Review に関する情報だけは visionOS のバージョンに書き込みます）

| 項目 | JSON のキー | 書き込み方 |
|---|---|---|
| カテゴリ | `primaryCategory`（必須）・`secondaryCategory`・`primarySubcategories` / `secondarySubcategories` | カテゴリの ID（`UTILITIES` など）で書きます。ID が違えば、使える一覧を出して書き込む前に止まります |
| コンテンツの権利 | `contentRightsDeclaration` | 第三者のコンテンツを使わないなら `DOES_NOT_USE_THIRD_PARTY_CONTENT` |
| 年齢制限 | `ageRating` | 質問ごとの回答。テンプレートはすべて「なし」（4+）なので、広告（`advertising`）・ほかの人の投稿（`userGeneratedContent`）などをアプリに合わせて見直します。質問が漏れていると PR の検査で落ちます |
| App Review に関する情報 | `review`（`demoAccountRequired`・`notes`） | 連絡先とデモアカウントは JSON に書かず、下の Secrets から渡します。値はログに出しません |
| 価格 | `pricing` | **App Store Connect で未設定のときだけ**無料にします。設定済みなら触りません |
| 配信状況 | `availability` | **App Store Connect で未設定のときだけ**、すべての国と地域（`"ALL"`）か指定した国と地域で配信します。設定済みなら触りません |

- 価格と配信状況は、最初のリリースの前に一度だけ決める項目です。JSON を書き換えても配信中のアプリの価格や配信先が変わらないよう、設定済みなら書き込みません。変えるときは App Store Connect の「価格および配信状況」で行います
- App Review に関する情報の連絡先は、次の Secrets から渡します。Organization の Secrets に登録しておくと、テンプレートから作ったリポジトリすべてで使われます。登録していなければ連絡先は書き込まず、Job Summary の「審査に出す前に App Store Connect で入力が要るもの」に出ます

| Secret | 内容 |
|---|---|
| `APP_REVIEW_CONTACT_FIRST_NAME` / `APP_REVIEW_CONTACT_LAST_NAME` | 審査の連絡先の名・姓 |
| `APP_REVIEW_CONTACT_PHONE` | 審査の連絡先の電話番号（`+81 90 1234 5678` のように国番号から） |
| `APP_REVIEW_CONTACT_EMAIL` | 審査の連絡先のメールアドレス |
| `APP_REVIEW_DEMO_ACCOUNT_NAME` / `APP_REVIEW_DEMO_ACCOUNT_PASSWORD` | デモアカウント（`review.demoAccountRequired` が `true` のアプリだけ。リポジトリの Secrets に登録します） |

**審査に出す前に App Store Connect で手入力するもの**

API が無い・アカウントで一度だけ行うなど、ワークフローで反映できないものです。

| 項目 | 理由・手順 |
|---|---|
| アプリの作成（名前・プライマリ言語・バンドル ID・SKU） | API で作れません。「5. App Store Connect にアプリを作成する」の手順で、Upload の Job Summary に出る値で作ります |
| App のプライバシー（収集するデータの申告） | API がありません。[TheaterPlayer/PrivacyInfo.xcprivacy](TheaterPlayer/PrivacyInfo.xcprivacy) とプライバシーポリシーに合わせて「App のプライバシー」で答え、公開します |
| ビルドの選択と審査への提出 | リリースの判断なので人が行います。輸出コンプライアンスは [TheaterPlayer/Info.plist](TheaterPlayer/Info.plist) の `ITSAppUsesNonExemptEncryption`（`false`）で申告済みなので、聞かれません |
| デジタルサービス法（EU）の取引業者の情報 | アプリごとではなくアカウントで一度だけ行います（「ビジネス」）。登録済みなら不要です |
| 使用許諾契約（EULA） | 初めて出すときに一度だけ。[docs/EULA.md](docs/EULA.md) の文を「App 情報」→「使用許諾契約」に設定します（LGPL の FFmpeg を使うため。下の「ライセンス」） |
| この版の Release | 審査に出すたびに作ります（下の「ライセンス」の「審査に出すときにすること」） |

流す順は、`Metadata/App Store` を dry-run で実行して Job Summary の差分を確かめ → `dry_run` を外して実行 → 最後に出る「審査に出す前に App Store Connect で入力が要るもの」を App Store Connect で埋める、です。

## アプリの構成

| 場所 | 役割 |
|---|---|
| [TheaterPlayer/Library](TheaterPlayer/Library) | ライブラリ（最初のウィンドウ）。「ファイル」・写真から選ぶ、最近の一覧から続きを再生する |
| [TheaterPlayer/Theater](TheaterPlayer/Theater) | 映画館（`ImmersiveSpace`、Full）。映画館のモデル・スクリーンの映像（`VideoMaterial(videoRenderer:)`）・空間オーディオのスピーカー・照明の演出・上映の進行（`ShowDirector`：開演の流れ・エンドロール）・開演のブザー・手元の操作パネル・座席表・字幕 |
| [TheaterPlayer/Model](TheaterPlayer/Model) | 再生の状態（`PlayerModel`）・設定（`Preferences`）・最近の一覧（`RecentItems`） |
| [TheaterPlayer/About](TheaterPlayer/About) | ライセンス（ライブラリのウィンドウのツールバーから開く）。使っているオープンソースのソフトウェアと、この版のソースの入手先 |
| [TheaterPlayer/Resources/Theater](TheaterPlayer/Resources/Theater) | 映画館のモデル（`Theater.usdz`）と配置（`TheaterLayout.json`）。[Tools/Theater](Tools/Theater/README.md) のスクリプトが書く |
| [TheaterPlayer/Resources/Licenses](TheaterPlayer/Resources/Licenses) | ライセンスの画面に出す全文（FFmpeg の LGPL 2.1・dav1d の BSD・このアプリの MIT） |
| [Packages/TheaterMedia](Packages/TheaterMedia) | 再生のエンジン。FFmpeg で開いてデコードし、映像は `AVSampleBufferVideoRenderer` へ、音声は映画館の音響処理へ。音の時計に映像を合わせる |
| [Packages/TheaterCore](Packages/TheaterCore) | `CinemaAudio`（映画館の音響処理：系統への振り分け・アップミックス・ベースマネジメント・低音・リミッター・スピーカーへの輪のバッファ）と、`TheaterScene`（映画館の空間：照明の状態・座席の組み立て・マスキング・スクリーンの曲面）。macOS でもテストできる |
| [Tools/Theater](Tools/Theater) | 映画館を作る Blender のスクリプトと、RealityKit で確かめる道具 |
| [Tools/StereoConvert](Tools/StereoConvert) | 2D の動画を、深度推定（Core ML）で左右に並べた 3D の動画に変換する Mac の道具 |

### 音の流れ

```
ファイル → FFmpeg（デコード → 48 kHz の float）→ CinemaProcessor（7.1.4 の系統へ振り分け・アップミックス → ベースマネジメント → 低音 → 音量の幅 → スピーカーごとの倍率と遅延 → リミッター）
        → SpeakerFeedRing → RealityKit の空間オーディオの音源（スピーカー 31 台の位置）
```

- サラウンドは同じ信号を何台ものスピーカーで鳴らす（映画館のアレイ）ので、スピーカーごとに 0〜6 ms ずらして音が濁らないようにしています
- 再生の時計は、音が実際に鳴った位置（描画の時刻）から求め、映像の時計（`AVSampleBufferRenderSynchronizer`）をそれに合わせます

## 構成

```
.
├── Configs/                      # xcconfig（署名情報・バージョン・Deployment Target）
├── TheaterPlayer/                # アプリ本体（SwiftUI / RealityKit）
├── TheaterPlayerTests/           # Unit テスト（Swift Testing）
├── TheaterPlayerUITests/         # UI テスト（XCTest）
├── TheaterPlayer.xcodeproj       # 共有スキーム TheaterPlayer を含む（パッケージのテストも実行する）
├── Packages/
│   ├── TheaterCore/              # 映画館の音響処理（CinemaAudio）と空間（TheaterScene）
│   ├── TheaterMedia/             # 再生のエンジン（FFmpeg）。Vendor/ は scripts/build-ffmpeg.sh が作る
│   └── RealityKitContent/        # Reality Composer Pro の素材（テンプレートから）
├── AppStore/                     # App Store の掲載情報（言語・撮る画面・説明文）
├── Tools/
│   ├── Theater/                  # 映画館のモデル（Blender のスクリプト・RealityKit で確かめる道具）
│   ├── StereoConvert/            # 2D の動画を 3D に変換する道具（Swift Package。モデルは Models/ に置き、git に入れない）
│   └── …                         # スクリーンショットの撮影と App Store Connect への反映
├── docs/                         # ExportOptions.plist のサンプル・使用許諾契約（EULA）の文案
├── scripts/                      # build-ffmpeg.sh・rename.sh
├── .swiftlint.yml                # SwiftLint 設定
└── .github/                      # Issue・PR のテンプレートと、ワークフロー（_build.yml・_archive.yml は FFmpeg を作ってキャッシュする）
```

- プロジェクトはフォルダ同期グループ（Xcode 16 以降の形式）で管理しているため、ファイルの追加・削除で pbxproj は変わりません
- SwiftLint は Build Tool Plugin として全ターゲットに適用され、CI では `swiftlint lint --strict` としても実行されます。ルールは [.swiftlint.yml](.swiftlint.yml) で管理します
- CI のワークフローは `*.xcodeproj` の名前と同名の共有スキームが存在することを前提にしています
- [TheaterPlayer/PrivacyInfo.xcprivacy](TheaterPlayer/PrivacyInfo.xcprivacy) はプライバシーマニフェストです（下の「プライバシーマニフェスト」）。データの収集・トラッキング・ほかの理由の申告が必要な API を足したら、ここと App Store Connect の「App のプライバシー」を更新してください

### プライバシーマニフェスト

トラッキングとデータの収集はしていません。理由の申告が要る API は、次のものを申告しています。

| カテゴリ | 理由 | 使っている所 |
|---|---|---|
| UserDefaults | `CA92.1`（アプリ自身だけが読み書きする設定） | 利用者の設定（`Preferences`） |
| File timestamp | `C617.1`（アプリのコンテナの中のファイル）・`3B52.1`（利用者が選んだファイル） | FFmpeg の `stat`・`fstat`・`lstat`。file のプロトコルが、開いたファイルの大きさと種類を `fstat` で見る |
| System boot time | `35F9.1`（アプリの中の出来事のあいだの経過時間）・`8FFB.1`（AVFAudio などの出来事の時刻の計算） | TheaterMedia の `mach_absolute_time`。音の描画で受け取る AVAudio の時刻（`hostTime`）と突き合わせ、音を最後に鳴らした時刻からの経過で映像を音に合わせる |

- 静的にリンクした FFmpeg が使う API も、このアプリの申告になります。漏れていると、アップロードで ITMS-91053（Missing API declaration）の指摘を受けます
- FFmpeg の構成（`scripts/build-ffmpeg.sh` の configure）を変えたときや、理由の申告が要る API を使うコードを足したときは、Release の実機向けのバイナリを `nm -u` で見て、[Apple の一覧](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)の関数を参照していないか確かめます

```bash
xcodebuild build -project TheaterPlayer.xcodeproj -scheme TheaterPlayer -configuration Release -destination 'generic/platform=visionOS' -derivedDataPath /tmp/TheaterPlayer-Release CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation
```

```bash
nm -u /tmp/TheaterPlayer-Release/Build/Products/Release-xros/TheaterPlayer.app/TheaterPlayer | grep -E '^_(stat|fstat|fstatat|lstat|getattrlist|getattrlistbulk|fgetattrlist|getattrlistat|statfs|statvfs|fstatfs|fstatvfs|mach_absolute_time)$'
```

- `ProcessInfo.systemUptime`・`UITextInputMode.activeInputModes` のような Objective-C のメソッドは `nm -u` に出ないので、コードを検索して確かめます。`sysctl`・`sysctlbyname`・`clock_gettime` はどのカテゴリにも入っていません
- 申告を変えたら、[TheaterPlayerTests/PrivacyManifestTests.swift](TheaterPlayerTests/PrivacyManifestTests.swift) の期待値も直します

### 多言語（ローカライズ）

英語（en）と日本語（ja）に対応しています。開発の言語は英語で、画面の文字はコードに英語で書き、訳は String Catalog に置きます。
利用者の言語にアプリが対応していないとき（ドイツ語など）は、開発の言語の英語が出ます。

| String Catalog | 中身 |
|---|---|
| [TheaterPlayer/Localizable.xcstrings](TheaterPlayer/Localizable.xcstrings) | 画面の文字・エラーの文言・「ファイル」App に置く案内 |
| [TheaterPlayer/InfoPlist.xcstrings](TheaterPlayer/InfoPlist.xcstrings) | Info.plist の文言（表示名 `CFBundleDisplayName`・書類の種類の名前 `CFBundleTypeName`）。コマンドラインのビルドでは抽出されないので、手で書いています（`manual`） |
| [TheaterPlayer/AppShortcuts.xcstrings](TheaterPlayer/AppShortcuts.xcstrings) | Siri のフレーズ。キーはコードの最初の英語のフレーズで、言語ごとに複数のフレーズ（`stringSet`）を持ちます。どのフレーズにも `${applicationName}` を 1 回入れます |
| [Packages/TheaterMedia/Sources/TheaterMedia/Localizable.xcstrings](Packages/TheaterMedia/Sources/TheaterMedia/Localizable.xcstrings) | 再生のエラーの文言（`MediaError(localized:)`・`check(_:_:)`。パッケージのバンドル `.module` から引く） |

- キーは英語の文言そのものです（`Text("Choose a File")`）。同じ英語で訳を変えたいときだけ、`String(localized: "key", defaultValue: "…")` で別のキーにします。意味の取りにくい短い語には、catalog か `comment:` で訳す人への説明を付けます
- 数と単位は [UnitFormat](TheaterPlayer/Theater/UnitFormat.swift)（割合・dB・秒・速さ・周波数）で書きます。`String(format: "%.0f 倍")` のように、単位を文字列に決め打ちしません
- 文字を足したら、Xcode でビルドすると catalog にキーが入ります（訳の無いものは「New」）。日本語の訳を入れてください。
  訳の漏れ・`%@` などの数の食い違いは [TheaterPlayerTests/LocalizationTests.swift](TheaterPlayerTests/LocalizationTests.swift) が見つけます
- コマンドラインのビルド（`xcodebuild`）では catalog は書き換わりません。ビルドの抽出結果（DerivedData の `*.stringsdata`）から `xcrun xcstringstool sync <catalog> --stringsdata <ファイル>...` で入れられます
- 言語を足すときは、catalog に言語を足して訳し、`LocalizationTests.languages`・`TheaterPlayer.xcodeproj` の `knownRegions`・`AppStore/languages.json`・`AppStore/metadata/<言語>.json` にも足します
- App Intents の名前・説明・Siri の返事は `Localizable.xcstrings` に入ります。日本語の Siri で「シアタープレイヤー」と呼べるよう、Info.plist の `INAlternativeAppNames` に別名を入れています
- 見え方は、Simulator の起動引数（Scheme の Run → Arguments）で確かめます。`-AppleLanguages (en)` で言語を、`-NSDoubleLocalizedStrings YES` で文字を倍の長さにした擬似ローカライズを出せます

## ライセンス

- このアプリ：[MIT License](LICENSE)
- FFmpeg：[LGPL 2.1 以降](https://ffmpeg.org/legal.html)（LGPL の構成。GPL・nonfree の部品は使いません）
- dav1d：[BSD 2-Clause](https://code.videolan.org/videolan/dav1d/-/blob/master/COPYING)
- Depth Anything V2 Small（Core ML 版）：[Apache 2.0](https://huggingface.co/apple/coreml-depth-anything-v2-small)。Mac の変換の道具だけが使い、アプリには入れません

### FFmpeg（LGPL）の扱い

FFmpeg はアプリに静的にリンクしています。LGPL 2.1 の条件は、次のようにして満たします（法律の助言を受けて決めたものではありません。商用で配るときは法務に確認してください）。

| LGPL 2.1 が求めること | このアプリでの対応 |
|---|---|
| FFmpeg を使っていること・LGPL であることを示し、ライセンスの全文を付ける | アプリの「ライセンス」の画面（ライブラリのウィンドウのツールバー）に、使い方・著作権・全文を出す |
| 配ったバイナリと同じ FFmpeg のソースを渡す | 審査に出す版ごとに GitHub の Release を作り、FFmpeg・dav1d のソースの配布物を添付する。パッチとビルドのスクリプトは、その版のタグのリポジトリにある |
| 利用者が FFmpeg を差し替えて作り直せる（第 6 条） | このアプリのソースをすべて公開しているので、差し替えた FFmpeg でビルドし直せる |
| 使用許諾契約で、改変とデバッグのための解析を禁じない・LGPL の権利を制限しない | App Store Connect に [docs/EULA.md](docs/EULA.md) の使用許諾契約を設定する（Apple の標準使用許諾契約を使い、オープンソースの部品のライセンスを優先させる） |

### 審査に出すときにすること

アプリの「ライセンス」の画面は、その版の Release（`v<MARKETING_VERSION>`）へ案内します。審査に出すたびに、出すビルドのコミット（App Store Connect に上げた Upload の実行のコミット）に、タグと Release を作ってください。

```bash
git tag v1.0.0 <コミット>
```

```bash
git push origin v1.0.0
```

```bash
gh release create v1.0.0 .build/ffmpeg/src/ffmpeg-9.0.2.tar.xz .build/ffmpeg/src/dav1d-1.5.4.tar.xz --title "v1.0.0" --notes "App Store に出した版のソースです。FFmpeg 9.0.2（LGPL 2.1 以降）と dav1d 1.5.4（BSD 2-Clause）のソースの配布物を添付しています。FFmpeg に当てたパッチとビルドのスクリプトは、このタグの scripts/ にあります。"
```

- 添付する 2 つは、`scripts/build-ffmpeg.sh` が公式の配布物を取得し、SHA-256 を確かめて置いたものです（一度ビルドすると `.build/ffmpeg/src/` にあります）
- 同じ版でビルドを出し直したときは、タグと Release を作り直してください
- FFmpeg・dav1d の版を上げたら、[TheaterPlayer/About/OpenSourceLicenses.swift](TheaterPlayer/About/OpenSourceLicenses.swift) の版も直します（`scripts/build-ffmpeg.sh` が食い違いを確かめて止まります）
