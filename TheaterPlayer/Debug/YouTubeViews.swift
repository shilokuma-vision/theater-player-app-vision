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

/// 操作パネルの「YouTube」のページ：検索・前のページ・閉じる
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
            Text(
                """
                Search results and videos appear on the screen. Shorts don’t play. \
                The sound doesn’t go through the theater’s sound system.
                """
            )
                .font(.footnote)
                .foregroundStyle(.secondary)
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
#endif
