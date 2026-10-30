//
//  OpenSourceLicenses.swift
//  TheaterPlayer
//
//  アプリに入れているオープンソースのソフトウェアと、そのライセンス（LGPL・BSD・MIT が求める表示）。
//  FFmpeg は LGPL 2.1 以降で、アプリに静的にリンクしている。利用者が FFmpeg を差し替えてアプリを作り直せるよう、
//  版ごとの GitHub の Release で、この版のソース（アプリ・FFmpeg を作るスクリプトとパッチ）と、
//  FFmpeg・dav1d のソースの配布物を配る（README の「リリース」）。
//

import Foundation

/// アプリに入れているオープンソースのソフトウェア
struct OpenSourceComponent: Identifiable, Sendable {
    let name: String
    let version: String
    let license: String
    let copyright: String
    /// アプリの中での使い方
    let usage: String
    /// ライセンスの全文（Resources/Licenses のファイルの名前。拡張子は txt）
    let licenseFile: String
    /// 元のソースの入手先
    let source: URL

    var id: String { name }

    /// ライセンスの全文（アプリに入れたファイルから読む）
    var licenseText: String? {
        Bundle.main.url(forResource: licenseFile, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

enum OpenSourceLicenses {
    /// scripts/build-ffmpeg.sh の FFMPEG_VERSION・DAV1D_VERSION と同じにする（スクリプトが食い違いを確かめる）
    static let ffmpegVersion = "9.0.2"
    static let dav1dVersion = "1.5.4"

    static let repository = URL(string: "https://github.com/shilokuma-vision/theater-player-app-vision")!

    /// この版の Release（この版のソースと、FFmpeg・dav1d のソースの配布物を置く）
    static var release: URL {
        repository.appending(path: "releases/tag/v\(appVersion)")
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static let components: [OpenSourceComponent] = [
        OpenSourceComponent(
            name: "FFmpeg",
            version: ffmpegVersion,
            license: "GNU Lesser General Public License 2.1 以降",
            copyright: "Copyright © the FFmpeg developers",
            usage: """
            動画・音楽のファイルを開き、映像・音声・字幕をデコードするのに使っています。\
            LGPL の構成（GPL・nonfree の部品は使わない）でビルドし、アプリに静的にリンクしています。\
            visionOS でビルドするためのパッチを当てています。
            """,
            licenseFile: "FFmpeg-LGPL-2.1",
            source: URL(string: "https://ffmpeg.org/releases/ffmpeg-\(ffmpegVersion).tar.xz")!
        ),
        OpenSourceComponent(
            name: "dav1d",
            version: dav1dVersion,
            license: "BSD 2-Clause License",
            copyright: "Copyright © 2018-2025, VideoLAN and dav1d authors",
            usage: "AV1 の映像をソフトウェアでデコードするのに使っています（FFmpeg から使う）。",
            licenseFile: "dav1d-BSD-2-Clause",
            source: URL(string: "https://downloads.videolan.org/pub/videolan/dav1d/\(dav1dVersion)/dav1d-\(dav1dVersion).tar.xz")!
        ),
        OpenSourceComponent(
            name: "Theater Player",
            version: appVersion,
            license: "MIT License",
            copyright: "Copyright © 2024 Shilokuma Inc.",
            usage: "このアプリ自身のソースです。",
            licenseFile: "TheaterPlayer-MIT",
            source: repository
        )
    ]
}
