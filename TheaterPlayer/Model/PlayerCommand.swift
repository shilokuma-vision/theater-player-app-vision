//
//  PlayerCommand.swift
//  TheaterPlayer
//
//  再生の操作。操作パネル・Now Playing（Siri・AirPods・コントロールセンター）・スクリーンをつまむ操作など、
//  どこから操作しても AppModel.perform(_:) の 1 か所を通す（入口によって振る舞いが変わらないように）。
//  システムの操作はメインスレッドの外から届くことがあるので、値はどのスレッドでも作れるようにする（nonisolated）。
//

import Foundation

nonisolated enum PlayerCommand: Equatable, Sendable {
    /// 再生中なら止め、止まっていれば再生する
    case togglePlay
    case play
    case pause
    /// 今の位置から動く（秒。負なら戻る）
    case skip(by: Double)
    /// その位置へ動く（秒）
    case seek(to: Double)
    case nextChapter
    /// 前のチャプターへ（今のチャプターに入って少し経っていれば、今のチャプターの始まりへ）
    case previousChapter
    /// 再生の速さ（0.5〜2.0）
    case setRate(Float)
    /// 開演の流れ（ブザー・暗転・幕）を省いて、すぐに本編を始める
    case startNow
    /// 畳んだ操作パネルを出す
    case showPanel

    /// 前のチャプターへ戻るとき、今のチャプターの始まりからこの秒数より後なら、今のチャプターの始まりへ戻る（音楽のアプリの「前へ」と同じ）
    static let restartThreshold: Double = 3
    /// チャプターの始まりに着いたとみなす幅（秒）。シークの直後の位置は始まりから少しずれるので、
    /// 続けて「次へ」を押したときに同じチャプターの始まりへ戻らないようにする
    static let chapterTolerance: Double = 1

    /// この操作で動く先の位置（秒）。位置を動かさない操作と、動く先が無いとき（最後のチャプターで「次へ」）は nil。
    /// time は今の位置、duration は長さ（分からなければ 0）、chapterStarts はチャプターの始まりの位置
    func seekTarget(from time: Double, duration: Double, chapterStarts: [Double]) -> Double? {
        switch self {
        case let .skip(seconds):
            clamp(time + seconds, duration: duration)
        case let .seek(target):
            clamp(target, duration: duration)
        case .nextChapter:
            chapterStarts.sorted().first { $0 > time + Self.chapterTolerance && (duration <= 0 || $0 < duration) }
        case .previousChapter:
            Self.previousChapterStart(from: time, chapterStarts: chapterStarts)
        case .togglePlay, .play, .pause, .setRate, .startNow, .showPanel:
            nil
        }
    }

    private func clamp(_ time: Double, duration: Double) -> Double {
        duration > 0 ? max(0, min(time, duration)) : max(0, time)
    }

    private static func previousChapterStart(from time: Double, chapterStarts: [Double]) -> Double? {
        let starts = chapterStarts.sorted()
        guard !starts.isEmpty else {
            return nil
        }
        // 今いるチャプター（最初のチャプターより前なら、頭から）
        guard let index = starts.lastIndex(where: { $0 <= time + chapterTolerance }) else {
            return 0
        }
        if time - starts[index] > restartThreshold {
            return starts[index]
        }
        return index > 0 ? starts[index - 1] : 0
    }
}
