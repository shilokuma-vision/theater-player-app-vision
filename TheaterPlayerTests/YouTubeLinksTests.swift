//
//  YouTubeLinksTests.swift
//  TheaterPlayerTests
//
//  デバッグ用の YouTube（デバッグのビルドだけ）の URL の判定
//

#if DEBUG
import Foundation
import Testing
@testable import TheaterPlayer

struct YouTubeLinksTests {
    /// 検索の URL：youtube.com の検索結果を、種類「動画」に絞って開く
    @Test
    func searchURL() throws {
        let url = try #require(YouTubeLinks.searchURL(for: "  Big Buck Bunny  "))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "www.youtube.com")
        #expect(components.path == "/results")
        #expect(components.queryItems?.first { $0.name == "search_query" }?.value == "Big Buck Bunny")
        #expect(components.queryItems?.first { $0.name == "sp" }?.value == "EgIQAQ==")
    }

    /// 日本語や記号も、URL の中でそのまま検索語になる
    @Test
    func searchURLEncodesQuery() throws {
        let url = try #require(YouTubeLinks.searchURL(for: "映画館 & 予告編"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "search_query" }?.value == "映画館 & 予告編")
    }

    /// 空白だけなら検索しない
    @Test(arguments: ["", "   ", "\n"])
    func emptyQueryHasNoURL(query: String) {
        #expect(YouTubeLinks.searchURL(for: query) == nil)
    }

    /// ショートを見分ける（通常の動画・ほかのサイトはショートでない）
    @Test(arguments: [
        ("https://www.youtube.com/shorts/abc123", true),
        ("https://m.youtube.com/shorts/abc123?feature=share", true),
        ("https://www.youtube.com/shorts", true),
        ("https://www.youtube.com/watch?v=abc123", false),
        ("https://www.youtube.com/results?search_query=shorts", false),
        ("https://example.com/shorts/abc123", false)
    ])
    func shorts(url: String, expected: Bool) throws {
        #expect(YouTubeLinks.isShorts(try #require(URL(string: url))) == expected)
    }

    /// 移れるのは YouTube と Google の https のページだけ
    @Test(arguments: [
        ("https://www.youtube.com/watch?v=abc123", true),
        ("https://m.youtube.com/", true),
        ("https://youtu.be/abc123", true),
        ("https://accounts.google.com/ServiceLogin", true),
        ("http://www.youtube.com/", false),
        ("https://example.com/", false),
        ("https://notyoutube.com/", false),
        ("https://youtube.com.example.com/", false),
        ("youtube://watch?v=abc123", false)
    ])
    func allowed(url: String, expected: Bool) throws {
        #expect(YouTubeLinks.isAllowed(try #require(URL(string: url))) == expected)
    }
}
#endif
