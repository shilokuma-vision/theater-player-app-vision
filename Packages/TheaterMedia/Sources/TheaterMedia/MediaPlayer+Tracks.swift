//
//  MediaPlayer+Tracks.swift
//  TheaterMedia
//
//  音声・字幕のトラックの切り替えと、別のファイルの字幕。
//

import Foundation

extension MediaPlayer {
    /// いま鳴らしている音声のトラック（ストリームの番号）
    public var selectedAudioTrack: Int? {
        currentSession?.audio?.streamIndex
    }

    /// いま出している、ファイルの中の字幕のトラック（別のファイルの字幕なら nil）
    public var selectedSubtitleTrack: Int? {
        currentSession?.subtitle?.streamIndex
    }

    /// 音声のトラックを替える（今の位置から鳴らし直す）
    public func selectAudioTrack(_ id: Int) throws {
        guard let session = currentSession, session.audio?.streamIndex != id else {
            return
        }
        let decoder = try makeAudioDecoder(session, index: id)
        session.setAudio(decoder)
        seek(to: currentTime)
    }

    /// 字幕のトラックを替える（nil なら字幕を消す）
    public func selectSubtitleTrack(_ id: Int?) throws {
        guard let session = currentSession else {
            return
        }
        subtitleStore.clear()
        guard let id else {
            session.setSubtitle(nil)
            return
        }
        session.setSubtitle(try makeSubtitleDecoder(session, index: id))
        // 字幕のパケットは読み込みのときにデコードするので、今の位置から読み直す
        seek(to: currentTime)
    }

    /// 別のファイル（.srt・.ass・.vtt など）の字幕を読み、それを出す
    public func loadExternalSubtitles(_ url: URL) async throws -> SubtitleTrack {
        let cues = try await Task.detached(priority: .userInitiated) { try ExternalSubtitles.load(url) }.value
        currentSession?.setSubtitle(nil)
        subtitleStore.replace(with: cues)
        return SubtitleTrack(
            id: -1,
            codec: url.pathExtension.lowercased(),
            language: nil,
            title: url.deletingPathExtension().lastPathComponent,
            isBitmap: false,
            isDefault: false,
            isForced: false,
            isExternal: true
        )
    }
}
