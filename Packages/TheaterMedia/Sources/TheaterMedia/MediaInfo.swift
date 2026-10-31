//
//  MediaInfo.swift
//  TheaterMedia
//
//  開いたファイルの情報（長さ・曲名・トラック・チャプター・ジャケット）。
//

import CoreGraphics
import Foundation

/// 開いたファイルの情報
public struct MediaInfo: Sendable {
    /// 長さ（秒。分からなければ nil）
    public let duration: Double?
    public let title: String?
    public let artist: String?
    public let album: String?
    /// 入れ物の形式（matroska,webm・mov,mp4 など）
    public let container: String
    public let videoTracks: [VideoTrack]
    public let audioTracks: [AudioTrack]
    public let subtitleTracks: [SubtitleTrack]
    public let chapters: [Chapter]
    /// ジャケット（音楽ファイルの埋め込みの画像）
    public let artwork: CGImage?

    /// 映像の無い（音楽の）ファイル
    public var isAudioOnly: Bool {
        videoTracks.isEmpty
    }
}

/// 映像のトラック
public struct VideoTrack: Sendable, Identifiable, Hashable {
    /// ストリームの番号
    public let id: Int
    public let codec: String
    public let width: Int
    public let height: Int
    /// 表示の縦横比（画素の縦横比を含む）
    public let displayAspect: Double
    public let frameRate: Double?
    /// 映像に付いた回転（度。時計回り）
    public let rotation: Int
    /// HDR（PQ・HLG）
    public let isHDR: Bool
    public let isInterlaced: Bool
    /// 入れ物に書いてある立体の並べ方（MKV の StereoMode・MOV の vexu。無ければ mono）
    public let stereo: StereoPacking
}

/// 音声のトラック
public struct AudioTrack: Sendable, Identifiable, Hashable {
    public let id: Int
    public let codec: String
    public let channels: Int
    /// チャンネルの並びの名前（5.1(side) など）
    public let layoutName: String
    public let sampleRate: Int
    public let language: String?
    public let title: String?
    public let isDefault: Bool
}

/// 字幕のトラック
public struct SubtitleTrack: Sendable, Identifiable, Hashable {
    public let id: Int
    public let codec: String
    public let language: String?
    public let title: String?
    /// 画像の字幕（PGS・DVD など）
    public let isBitmap: Bool
    public let isDefault: Bool
    public let isForced: Bool
    /// 別のファイル（.srt など）から読んだ字幕
    public let isExternal: Bool
}

/// チャプター
public struct Chapter: Sendable, Identifiable, Hashable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String?
}

/// 映像の形式（デコードを始めて分かること。スクリーンの縦横比・向きに使う）
public struct VideoFormat: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let displayAspect: Double
    public let rotation: Int
    public let isHDR: Bool

    /// 回転を考えた、見た目の縦横比
    public var visibleAspect: Double {
        rotation.isMultiple(of: 180) ? displayAspect : 1 / displayAspect
    }
}

/// 再生の状態
public enum PlaybackState: Sendable, Equatable {
    case idle
    case opening
    case paused
    case playing
    /// データを待っている（シークの直後など）
    case buffering
    case ended
    case failed(String)
}

/// FFmpeg のエラー
public struct MediaError: Error, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    /// 文言を、パッケージの String Catalog（Localizable.xcstrings）で利用者の言語に訳して作る
    init(localized message: String.LocalizationValue) {
        self.message = String(localized: message, bundle: .module)
    }

    public var errorDescription: String? {
        message
    }
}
