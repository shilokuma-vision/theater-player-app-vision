# 使用許諾契約（EULA）の文案

App Store Connect の「App 情報」→「使用許諾契約」に設定する、独自の使用許諾契約の文案です。
このアプリは LGPL 2.1 以降の FFmpeg を静的にリンクしているため、App Store の使用許諾契約が LGPL の認める権利を制限しないことを明記します（README の「ライセンス」）。

- 設定は、初めて App Store に出すときの 1 度だけです。文を変えたら、App Store Connect の設定も直してください
- `<連絡先>` は、問い合わせを受けるメールアドレスか Web ページにしてください
- 日本語と英語を続けて 1 つの文として設定します（App Store Connect の使用許諾契約は、すべての国で同じ文が表示されます）
- 法律の助言を受けて作った文ではありません。商用で配るときは、法務に確認してください

## 設定する文

```text
Theater Player 使用許諾契約

1. 本アプリの利用には、Apple の標準使用許諾契約（Licensed Application End User License Agreement、https://www.apple.com/legal/internet-services/itunes/dev/stdeula/ ）が適用されます。ただし、次の 2・3 が優先します。

2. 本アプリには、次のオープンソースのソフトウェアが含まれ、それぞれのライセンスで提供されます。
   - FFmpeg：GNU Lesser General Public License 2.1 以降（LGPL）
   - dav1d：BSD 2-Clause License
   本契約（Apple の標準使用許諾契約を含む）のいずれの条項も、これらのライセンスが利用者に与える権利を制限しません。これには、これらのソフトウェアを複製・改変・再配布する権利と、改変した FFmpeg を本アプリで使うためにデバッグを目的として本アプリを解析（リバースエンジニアリング）する権利を含みます。これらのソフトウェアについて、本契約とそのライセンスが食い違うときは、そのライセンスが優先します。

3. 本アプリ自身のソースは MIT License で公開されています。各版のソース（本アプリ、FFmpeg を作るスクリプトとパッチ）と、FFmpeg・dav1d のソースの配布物は、次の場所から入手できます。本アプリの「ライセンス」の画面からも開けます。
   https://github.com/shilokuma-vision/theater-player-app-vision/releases

4. 本アプリについての問い合わせ：<連絡先>

---

Theater Player End User License Agreement

1. Your use of this app is governed by Apple's Licensed Application End User License Agreement (https://www.apple.com/legal/internet-services/itunes/dev/stdeula/), except that sections 2 and 3 below take precedence.

2. This app includes the following open-source software, each provided under its own license:
   - FFmpeg: GNU Lesser General Public License, version 2.1 or later (LGPL)
   - dav1d: BSD 2-Clause License
   Nothing in this agreement (including Apple's Licensed Application End User License Agreement) restricts the rights granted to you by these licenses, including the rights to copy, modify, and redistribute that software, and to reverse engineer this app for the purpose of debugging modifications that let it use a modified version of FFmpeg. Where this agreement conflicts with those licenses with respect to that software, those licenses prevail.

3. The source code of this app is available under the MIT License. The source code of each version (this app, and the scripts and patches used to build FFmpeg) and the source distributions of FFmpeg and dav1d are available at:
   https://github.com/shilokuma-vision/theater-player-app-vision/releases
   You can also open this location from the "ライセンス" (Licenses) screen in the app.

4. Contact: <contact>
```
