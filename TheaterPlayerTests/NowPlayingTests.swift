//
//  NowPlayingTests.swift
//  TheaterPlayerTests
//
//  システムの Now Playing に見せる情報。
//

import MediaPlayer
import Testing
@testable import TheaterPlayer

@MainActor
struct NowPlayingTests {
    func item(duration: Double = 5_400, rate: Double = 1, isAudioOnly: Bool = false) -> NowPlaying.Item {
        NowPlaying.Item(
            title: "映画",
            artist: nil,
            album: nil,
            duration: duration,
            elapsed: 1_234.5,
            rate: rate,
            isAudioOnly: isAudioOnly,
            chapterCount: 0
        )
    }

    /// 題名・長さ・位置・速さ・動画であることを見せる
    @Test func describesAMovie() {
        let info = NowPlaying.info(for: item())
        #expect(info[MPMediaItemPropertyTitle] as? String == "映画")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 5_400)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 1_234.5)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.video.rawValue)
        #expect(info[MPMediaItemPropertyArtist] == nil)
    }

    /// 止めているあいだは速さを 0 にする（システムが位置を進めないように）
    @Test func pausedItemHasNoRate() {
        #expect(NowPlaying.info(for: item(rate: 0))[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    }

    /// 音楽は、アーティストとアルバムも見せる
    @Test func describesMusic() {
        var music = item(isAudioOnly: true)
        music.artist = "アーティスト"
        music.album = "アルバム"
        let info = NowPlaying.info(for: music)
        #expect(info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.audio.rawValue)
        #expect(info[MPMediaItemPropertyArtist] as? String == "アーティスト")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "アルバム")
    }

    /// 長さが分からないときは、長さを見せない（0 秒の映画にしない）
    @Test func unknownDurationIsOmitted() {
        #expect(NowPlaying.info(for: item(duration: 0))[MPMediaItemPropertyPlaybackDuration] == nil)
    }
}
