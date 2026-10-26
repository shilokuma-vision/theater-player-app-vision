# VisionOSTemplateApp

visionOS Application Template (SwiftUI)

visionOS（Apple Vision Pro）アプリのリポジトリを新規作成するときの GitHub テンプレートリポジトリです。
SwiftUI / RealityKit のプロジェクト一式と、ビルド・テスト・Archive・TestFlight 配信までの GitHub Actions ワークフローを含みます。
[shilokuma-inc/template-app-ios](https://github.com/shilokuma-inc/template-app-ios) の visionOS 版で、CI や App Store の掲載情報の仕組みは iOS 版と同じ作りです。

## Environment

- Xcode 26.6
- visionOS 26.0 以上
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
          <a href="https://github.com/shilokuma-vision/template-app-visionos/actions/workflows/build.yml?query=branch%3Amain">
            <img src="https://github.com/shilokuma-vision/template-app-visionos/actions/workflows/build.yml/badge.svg?branch=main" alt="Build">
          </a>
        </td>
        <td style="border:2px double #000080;text-align:center;">
          <a href="https://github.com/shilokuma-vision/template-app-visionos/actions/workflows/archive.yml?query=branch%3Amain">
            <img src="https://github.com/shilokuma-vision/template-app-visionos/actions/workflows/archive.yml/badge.svg?branch=main" alt="Archive">
          </a>
        </td>
        <td style="border:2px double #000080;text-align:center;">
        </td>
      </tr>
      <tr>
        <td style="border:2px double #000080;text-align:left;">develop</td>
        <td style="border:2px double #000080;text-align:center;">
          <a href="https://github.com/shilokuma-vision/template-app-visionos/actions/workflows/build.yml?query=branch%3Adevelop">
            <img src="https://github.com/shilokuma-vision/template-app-visionos/actions/workflows/build.yml/badge.svg?branch=develop" alt="Build">
          </a>
        </td>
        <td style="border:2px double #000080;text-align:center;">
        </td>
        <td style="border:2px double #000080;text-align:center;">
          <a href="https://github.com/shilokuma-vision/template-app-visionos/actions/workflows/upload.yml?query=branch%3Adevelop">
            <img src="https://github.com/shilokuma-vision/template-app-visionos/actions/workflows/upload.yml/badge.svg?branch=develop" alt="Upload">
          </a>
        </td>
      </tr>
    </tbody>
  </table>
</div>

## テンプレートの使い方

### 1. リポジトリを作成する

GitHub の「Use this template」からリポジトリを作成し、clone します。

### 2. プロジェクト名を変更する

`VisionOSTemplateApp` を新しいアプリ名に一括変更するスクリプトを用意しています。
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

- 撮影はアプリの撮影モード（[VisionOSTemplateApp/Screenshot/ScreenshotDemo.swift](VisionOSTemplateApp/Screenshot/ScreenshotDemo.swift)）で行います。`Tools/capture_screenshots.sh` が `-screenshot-demo -screenshot-scene <名前>` と言語を起動引数で渡し、アプリはデモデータで目的の画面を開きます
- 画面を足すときは、`ScreenshotDemo.Scene` に case を足し、`VisionOSTemplateApp.swift` の `rootView` で開く画面を返し、`AppStore/screenshots.json` の `scenes` に同じ名前を足します（1 表示サイズにつき 10 枚まで）
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
| App のプライバシー（収集するデータの申告） | API がありません。[VisionOSTemplateApp/PrivacyInfo.xcprivacy](VisionOSTemplateApp/PrivacyInfo.xcprivacy) とプライバシーポリシーに合わせて「App のプライバシー」で答え、公開します |
| ビルドの選択と審査への提出 | リリースの判断なので人が行います。輸出コンプライアンスは [VisionOSTemplateApp/Info.plist](VisionOSTemplateApp/Info.plist) の `ITSAppUsesNonExemptEncryption`（`false`）で申告済みなので、聞かれません |
| デジタルサービス法（EU）の取引業者の情報 | アプリごとではなくアカウントで一度だけ行います（「ビジネス」）。登録済みなら不要です |

流す順は、`Metadata/App Store` を dry-run で実行して Job Summary の差分を確かめ → `dry_run` を外して実行 → 最後に出る「審査に出す前に App Store Connect で入力が要るもの」を App Store Connect で埋める、です。

## アプリの構成

Xcode の visionOS アプリのテンプレート（Initial Scene: Window、Immersive Space Renderer: RealityKit、Immersive Space: Mixed）と同じ構成です。

| ファイル | 役割 |
|---|---|
| [VisionOSTemplateApp.swift](VisionOSTemplateApp/VisionOSTemplateApp.swift) | `WindowGroup`（最初に開くウィンドウ）と `ImmersiveSpace`（周りの空間に出す内容）を宣言する |
| [ContentView.swift](VisionOSTemplateApp/ContentView.swift) | ウィンドウの中身。`Model3D` で RealityKitContent の `Scene` を出し、Immersive Space を開閉するボタンを置く |
| [ImmersiveSpace/](VisionOSTemplateApp/ImmersiveSpace) | Immersive Space に出す `ImmersiveView`（`RealityView` で `Immersive` を読み込む）と、開閉のボタン |
| [AppModel.swift](VisionOSTemplateApp/AppModel.swift) | Immersive Space の開閉の状態など、アプリ全体で共有する状態（`@Observable`） |
| [Info.plist](VisionOSTemplateApp/Info.plist) | Scene Manifest。複数のシーン（ウィンドウと Immersive Space）を使い、Immersive Space を Mixed で始める |
| [Packages/RealityKitContent](Packages/RealityKitContent) | 3D の素材（USD）を置く Swift Package。Reality Composer Pro で編集する（[README](Packages/RealityKitContent/README.md)） |

- アプリターゲットは RealityKitContent をリンク済みです。素材を足すときは `RealityKitContent.rkassets` にファイルを置くだけで、pbxproj を変える必要はありません
- 最初のシーンをウィンドウではなくボリューム（`.windowStyle(.volumetric)`）にするときは、Info.plist の `UIApplicationPreferredDefaultSceneSessionRole` を `UIWindowSceneSessionRoleVolumetricApplication` に変えます
- Immersive Space を Full / Progressive にするときは、`immersionStyle` と Info.plist の `UISceneInitialImmersionStyle` を揃えて変えます

## 構成

```
.
├── Configs/                      # xcconfig（署名情報・バージョン・Deployment Target）
├── VisionOSTemplateApp/          # アプリ本体（SwiftUI / RealityKit）
├── VisionOSTemplateAppTests/     # Unit テスト（Swift Testing）
├── VisionOSTemplateAppUITests/   # UI テスト（XCTest）
├── VisionOSTemplateApp.xcodeproj # 共有スキーム VisionOSTemplateApp を含む
├── Packages/RealityKitContent/   # 3D の素材（Reality Composer Pro）
├── AppStore/                     # App Store の掲載情報（言語・撮る画面・説明文）
├── Tools/                        # スクリーンショットの撮影と App Store Connect への反映
├── docs/                         # ExportOptions.plist のサンプル
├── scripts/                      # rename.sh
├── .swiftlint.yml                # SwiftLint 設定
└── .github/
    ├── ISSUE_TEMPLATE/           # Issue テンプレート
    ├── pull_request_template.md
    ├── scripts/                  # check-app-store-app.rb（App Store Connect のアプリの有無を確認）
    └── workflows/
        ├── _build.yml            # 共通処理: ビルド + テスト + SwiftLint（workflow_call）
        ├── _archive.yml          # 共通処理: Archive → Export（→ Upload）（workflow_call）
        ├── build.yml             # 全ブランチの push / Fork からの PR
        ├── archive.yml           # main の push
        ├── upload.yml            # develop / release/** の push
        ├── app-store-*.yml       # App Store の掲載情報の反映（手動実行）
        └── verify-app-store-metadata.yml  # 掲載情報の検査（PR）
```

- プロジェクトはフォルダ同期グループ（Xcode 16 以降の形式）で管理しているため、ファイルの追加・削除で pbxproj は変わりません
- SwiftLint は Build Tool Plugin として全ターゲットに適用され、CI では `swiftlint lint --strict` としても実行されます。ルールは [.swiftlint.yml](.swiftlint.yml) で管理します
- CI のワークフローは `*.xcodeproj` の名前と同名の共有スキームが存在することを前提にしています
- [VisionOSTemplateApp/PrivacyInfo.xcprivacy](VisionOSTemplateApp/PrivacyInfo.xcprivacy) はプライバシーマニフェストです。UserDefaults（`@AppStorage`）の利用だけを申告しています。データの収集・トラッキング・ほかの理由の申告が必要な API を足したら、ここと App Store Connect の「App のプライバシー」を更新してください

## License

[MIT License](LICENSE)
