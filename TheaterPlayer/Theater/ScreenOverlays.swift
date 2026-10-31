//
//  ScreenOverlays.swift
//  TheaterPlayer
//
//  スクリーンの上に出す物：字幕（文字・画像）と、音楽のときのジャケットと曲名。
//  映像の範囲の大きさ（幅 1,600 pt）で描き、TheaterView がスクリーンの映像の幅に合わせて大きくする。
//

import SwiftUI
import TheaterMedia

/// 字幕。文字は映像の下寄りに、画像の字幕は字幕に書かれた位置に出す
struct SubtitleOverlay: View {
    let cues: [SubtitleCue]
    /// 映像の範囲の縦横比
    let aspect: Double
    static let width: CGFloat = 1_600

    var body: some View {
        let height = Self.width / CGFloat(max(aspect, 0.5))
        ZStack(alignment: .bottom) {
            Color.clear
            ForEach(cues.filter { $0.image != nil }) { cue in
                if let image = cue.image, let rect = cue.imageRect {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: rect.width * Self.width, height: rect.height * height)
                        .position(x: (rect.midX) * Self.width, y: rect.midY * height)
                }
            }
            let lines = cues.compactMap(\.text).joined(separator: "\n")
            if !lines.isEmpty {
                Text(lines)
                    .font(.system(size: height * 0.055, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 2)
                    .shadow(color: .black.opacity(0.8), radius: 6)
                    .padding(.horizontal, Self.width * 0.08)
                    .padding(.bottom, height * 0.07)
            }
        }
        .frame(width: Self.width, height: height)
        .allowsHitTesting(false)
    }
}

/// 音楽：スクリーンにジャケットと曲名
struct NowPlayingScreen: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let player = appModel.player
        HStack(spacing: 60) {
            Group {
                if let artwork = player.info?.artwork {
                    Image(decorative: artwork, scale: 1).resizable().scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 24).fill(.white.opacity(0.08))
                        .overlay(Image(systemName: "music.note").font(.system(size: 160)).foregroundStyle(.white.opacity(0.6)))
                }
            }
            .frame(width: 520, height: 520)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            VStack(alignment: .leading, spacing: 16) {
                Text(player.title).font(.system(size: 64, weight: .bold)).lineLimit(2)
                if let artist = player.info?.artist {
                    Text(artist).font(.system(size: 40)).foregroundStyle(.white.opacity(0.8))
                }
                if let album = player.info?.album {
                    Text(album).font(.system(size: 32)).foregroundStyle(.white.opacity(0.6))
                }
                ProgressView(value: min(player.currentTime, max(player.duration, 1)), total: max(player.duration, 1))
                    .tint(.white)
                    .frame(width: 700)
                Text(verbatim: "\(TimeFormat.clock(player.currentTime)) / \(TimeFormat.clock(player.duration))")
                    .font(.system(size: 28)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
        }
        .padding(60)
        .frame(width: 1_600, height: 800)
        .allowsHitTesting(false)
    }
}
