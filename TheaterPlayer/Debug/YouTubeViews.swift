//
//  YouTubeViews.swift
//  TheaterPlayer
//
//  デバッグ用の YouTube の画面（デバッグのビルドだけ）：スクリーンの前に置くページと、操作パネルの「YouTube」のページ。
//

#if DEBUG
import SwiftUI
import WebKit

/// スクリーンの前に置く YouTube のページ。この大きさで描き、TheaterView がスクリーンの幅（16:9 の範囲）に合わせて大きくする
struct YouTubeScreen: View {
    @Environment(AppModel.self) private var appModel
    /// ページの幅・高さ（pt）。広すぎると、遠くのスクリーンで文字が小さくなる
    static let size = CGSize(width: 1_280, height: 720)

    var body: some View {
        Group {
            if let page = appModel.youTube.page {
                WebView(page)
                    .onChange(of: page.url) {
                        appModel.youTube.urlChanged(page.url)
                    }
            } else {
                Color.clear
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// 操作パネルの「YouTube」のページ：検索・前のページ・閉じる・映画館の音響に通す
struct YouTubePage: View {
    @Binding var page: ControlPanel.Page
    @Environment(AppModel.self) private var appModel
    @State private var query = ""

    var body: some View {
        let browser = appModel.youTube
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "YouTube (Debug)", page: $page)
            HStack {
                TextField("Search YouTube", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit(search)
                    .accessibilityIdentifier("youTubeQuery")
                Button("Search", systemImage: "magnifyingglass", action: search)
                    .disabled(YouTubeLinks.searchURL(for: query) == nil)
                    .accessibilityIdentifier("youTubeSearch")
            }
            Text("Search results and videos appear on the screen. Shorts don’t play.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            YouTubeSoundControls(browser: browser)
            if let notice = browser.notice {
                Text(notice).font(.footnote).foregroundStyle(.orange)
            }
            if let current = browser.page {
                Text(current.title.nonEmpty ?? String(localized: "Loading…"))
                    .lineLimit(1)
                HStack {
                    Button {
                        browser.goBack()
                    } label: {
                        Label("Previous Page", systemImage: "chevron.backward")
                    }
                    .disabled(!browser.canGoBack)
                    Spacer()
                    Button {
                        browser.close()
                    } label: {
                        Label("Close YouTube", systemImage: "xmark.circle")
                    }
                    .accessibilityIdentifier("youTubeClose")
                }
            }
        }
    }

    /// 再生中の動画を止めてから、スクリーンに検索結果を出す
    private func search() {
        guard YouTubeLinks.searchURL(for: query) != nil else {
            return
        }
        appModel.perform(.pause)
        appModel.youTube.search(query)
    }
}

/// 「映画館の音響に通す」のスイッチと、通しているあいだの様子（届いた音・音と映像のずれ）と、ずれの調整。
/// デバッグ用の確認の画面なので、文言は String Catalog に入れない（リリースのビルドに文字列を入れない。verbatim の日本語だけ）
private struct YouTubeSoundControls: View {
    @Bindable var browser: YouTubeBrowser

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $browser.routesSoundThroughTheater) {
                Text(verbatim: "映画館の音響に通す")
            }
            .accessibilityIdentifier("youTubeTheaterSound")
            if browser.routesSoundThroughTheater {
                ForEach(lines, id: \.self) { line in
                    Text(verbatim: line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let warning {
                    Text(verbatim: warning).font(.footnote).foregroundStyle(.orange)
                }
                Stepper(value: $browser.soundDelay, in: -300...300, step: 10) {
                    Text(verbatim: "音のずれの調整：\(browser.soundDelay > 0 ? "+" : "")\(browser.soundDelay) ms（＋で音を遅らせる）")
                        .font(.footnote)
                }
            }
        }
    }

    private var lines: [String] {
        var lines = ["ページが読み込んだ音声を写して、映画館の音響の処理（31 本の空間オーディオ）から、映像に合わせて鳴らします。"]
        guard let report = browser.soundReport else {
            return lines
        }
        if !report.format.isEmpty {
            lines.append("音声：\(report.format)・先まで \(String(format: "%.1f", report.bufferedAhead)) 秒ぶん届いている")
        }
        if report.isPlaying {
            lines.append(
                "音と映像のずれの見込み：\(Self.signed(report.offset)) ms（\(Int(report.lead.rounded())) ms 先の音を鳴らしている）・" +
                    "合わせ直し \(report.resyncs) 回"
            )
            let level = report.peak > 0 ? "\(Int((20 * log10(report.peak)).rounded())) dBFS" : "無音"
            lines.append("音のピーク：\(level)・音の無かった所 \(Int(report.missing.rounded())) ms")
        }
        // 空間オーディオが止まっていないか（実機で、止まって鳴らないことがあった）
        lines.append("空間オーディオ：描画 \(Int(report.renders.rounded())) 回/秒・鳴らしている音源 \(report.readers) 本")
        let event = browser.soundSession.lastEvent
        lines.append("音声のセッション：\(browser.soundSession.summary)\(event.isEmpty ? "" : "（最後の知らせ：\(event)）")")
        lines.append(contentsOf: browser.soundNotes.suffix(4))
        return lines
    }

    private var warning: String? {
        guard let page = browser.soundPage else {
            return browser.page == nil ? nil : "ページの準備を待っています。"
        }
        if page.active.isEmpty {
            return "再生している動画の音声（MSE）が見つかりません。動画を再生すると鳴ります（見つかるまではページの音のまま）。"
        }
        let guardState = browser.soundGuard
        if guardState.gaveUp {
            return "映画館の空間オーディオが止まったまま鳴らせないので、ページの音に戻しました（スイッチを入れ直すと、もう一度試します）。"
        }
        if guardState.silentSeconds > 0 || (guardState.heals > 0 && !guardState.mutesOriginal) {
            return "映画館の空間オーディオが止まっています。鳴らし直しています（ページの音はそのまま）。"
        }
        if let report = browser.soundReport {
            if abs(report.rate - 1) >= 0.01 {
                return "速さが 1 倍でないあいだは、ページの音のまま鳴らします。"
            }
            if !report.problem.isEmpty {
                return "音声を読めません：\(report.problem)"
            }
            if report.isPlaying, report.missing > 500 {
                return "鳴らす所の音がまだ届いていません。"
            }
        }
        return nil
    }

    private static func signed(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }
}
#endif
