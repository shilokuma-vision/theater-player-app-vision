//
//  YouTubeBrowser.swift
//  TheaterPlayer
//
//  デバッグ用：YouTube の動画を検索して、スクリーンの前で再生する（デバッグのビルドだけ。リリースには入れない）。
//  youtube.com のページを、そのまま WebView で開く（検索結果も再生も YouTube のページ）。
//  YouTube の利用規約に沿うよう、動画の URL を抜き出したり、ダウンロードしたりはしない。API の鍵も使わない。
//  音は WebView から鳴り、映画館の音響の処理（空間オーディオ）は通らない。
//

#if DEBUG
import Foundation
import Observation
import WebKit

@Observable
final class YouTubeBrowser {
    /// 開いている YouTube のページ（閉じているあいだは nil）
    private(set) var page: WebPage?
    /// ショートを開こうとして戻した、などの知らせ
    private(set) var notice: String?

    var isOpen: Bool {
        page != nil
    }

    var canGoBack: Bool {
        !(page?.backForwardList.backList.isEmpty ?? true)
    }

    /// query で検索した結果を開く（閉じていれば開く）
    func search(_ query: String) {
        guard let url = YouTubeLinks.searchURL(for: query) else {
            return
        }
        let page = page ?? makePage()
        self.page = page
        notice = nil
        page.load(url)
    }

    /// 前のページへ戻る
    func goBack() {
        guard let page, let item = page.backForwardList.backList.last else {
            return
        }
        page.load(item)
    }

    /// 閉じる（再生を止めて、ページを捨てる）
    func close() {
        guard let page else {
            return
        }
        self.page = nil
        notice = nil
        page.stopLoading()
        Task {
            await page.pauseAllMediaPlayback()
        }
    }

    /// ページの URL が変わった。YouTube の中の移動は読み込み直さずに URL だけ変わる（NavigationDeciding を通らない）ので、ここでもショートを見る
    func urlChanged(_ url: URL?) {
        guard let url, YouTubeLinks.isShorts(url) else {
            return
        }
        blockedShorts()
        // 今いる履歴の項目がショートのときだけ戻る。読み込みを始めただけ（NavigationDeciding が止める）なら、まだ移っていないので戻らない
        guard let current = page?.backForwardList.currentItem?.url, YouTubeLinks.isShorts(current) else {
            return
        }
        goBack()
    }

    private func blockedShorts() {
        notice = String(localized: "Shorts don’t play.")
    }

    private func makePage() -> WebPage {
        var configuration = WebPage.Configuration()
        // 見た物・ログインを残さない
        configuration.websiteDataStore = .nonPersistent()
        // 全画面にせず、スクリーンの前のページの中で再生する
        configuration.mediaPlaybackBehavior = .allowsInlinePlayback
        let decider = YouTubeNavigationDecider { [weak self] in
            self?.blockedShorts()
        }
        return WebPage(configuration: configuration, navigationDecider: decider)
    }
}

/// YouTube の外へは移らない。ショートも開かない
struct YouTubeNavigationDecider: WebPage.NavigationDeciding {
    let blockedShorts: () -> Void

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        // ページの中の枠（埋め込みの広告など）は、そのまま読む
        guard action.target?.isMainFrame != false else {
            return .allow
        }
        guard let url = action.request.url else {
            return .cancel
        }
        if YouTubeLinks.isShorts(url) {
            blockedShorts()
            return .cancel
        }
        return YouTubeLinks.isAllowed(url) ? .allow : .cancel
    }
}

/// YouTube の URL
enum YouTubeLinks {
    /// 移ってよいホスト（YouTube と、ログイン・同意の Google）。サブドメイン（www.・m.・accounts. など）も含む
    static let allowedDomains = ["youtube.com", "youtu.be", "google.com"]

    /// 検索結果のページ。種類を「動画」に絞る（チャンネル・再生リストを出さない）。空なら nil
    static func searchURL(for query: String) -> URL? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return nil
        }
        var components = URLComponents(string: "https://www.youtube.com/results")
        components?.queryItems = [
            URLQueryItem(name: "search_query", value: query),
            // 検索の絞り込みの「種類：動画」
            URLQueryItem(name: "sp", value: "EgIQAQ==")
        ]
        return components?.url
    }

    /// ショート（/shorts/<id> と、ショートの一覧の /shorts）
    static func isShorts(_ url: URL) -> Bool {
        isAllowed(url) && url.pathComponents.dropFirst().first?.lowercased() == "shorts"
    }

    /// YouTube の中（とログイン・同意の Google）の https のページか
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else {
            return false
        }
        return allowedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
#endif
