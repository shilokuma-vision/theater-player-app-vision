//
//  CreditsFinder.swift
//  TheaterPlayer
//
//  エンドロールの始まりを見つける（エンドロールで客電を少し上げるため）。本編の途中で明るくしないことを優先し、
//  確かでなければ何もしない。
//  1. チャプターの名前（Credits・End Titles・エンドロール など）。作品の後半にあるものだけ
//  2. チャプターが無ければ：長い作品（60 分以上）の終わりの 12 分の中で、黒地に白い文字のような暗い画面が 30 秒続いたところ
//  3. どちらも無ければ、見つからない（客電は上映中のまま）
//

import Foundation
import TheaterMedia

struct CreditsFinder {
    /// チャプターの名前・始まり（秒）
    struct Mark: Equatable {
        let start: Double
        let title: String?
    }

    /// エンドロールらしいチャプターの名前（小文字にして、含んでいるかで比べる）
    static let creditKeywords = [
        "credit", "end title", "endtitle", "end roll", "endroll", "エンドロール", "エンドクレジット", "スタッフロール", "クレジット"
    ]
    /// 始まりのクレジット（Opening Credits など）は除く
    static let openingKeywords = ["opening", "オープニング"]
    /// 暗い画面で見つけるのは、この長さ（秒）より長い作品だけ（短い動画は、終わり近くの暗い場面をエンドロールと間違えやすい）
    static let darkMinimumDuration: Double = 60 * 60
    /// 暗い画面を探す、終わりからの範囲（秒）
    static let darkWindow: Double = 12 * 60
    /// 暗い画面がこの秒数続いたら、エンドロールとみなす
    static let darkHold: Double = 30
    /// 暗い画面：3 つの区画の明るさ（リニア。1 が SDR の白）の平均がこれより暗く、どの区画もこの 2 倍より暗い
    static let darkLevel: Float = 0.05
    /// 色が薄い（白い文字と黒地）：明るさの最大に対する、色の幅（RGB の最大 − 最小）の割合がこれより小さい
    static let neutralChroma: Float = 0.35

    /// 作品の長さ（秒。分からなければ暗い画面では探さない）
    let duration: Double?
    /// 暗い画面が続き始めた時刻
    private var darkSince: Double?
    private var lastTime: Double?

    init(duration: Double?) {
        self.duration = duration
    }

    // MARK: - チャプター

    /// エンドロールのチャプターの始まり。作品の後半にある、エンドロールらしい名前のチャプターのうち、いちばん早いもの
    static func chapterStart(_ marks: [Mark], duration: Double?) -> Double? {
        guard let total = duration ?? marks.map(\.start).max(), total > 0 else {
            return nil
        }
        return marks
            .filter { mark in
                guard let title = mark.title?.lowercased(), mark.start >= total / 2 else {
                    return false
                }
                return creditKeywords.contains { title.contains($0) } && !openingKeywords.contains { title.contains($0) }
            }
            .map(\.start)
            .min()
    }

    static func chapterStart(_ chapters: [Chapter], duration: Double?) -> Double? {
        chapterStart(chapters.map { Mark(start: $0.start, title: $0.title) }, duration: duration)
    }

    // MARK: - 暗い画面

    /// 本編を流しているあいだ、スクリーンの光を渡す。エンドロールだと分かったら、その始まり（暗くなった時刻）を返す
    mutating func observe(time: Double, light: ScreenLight) -> Double? {
        defer { lastTime = time }
        guard let duration, duration >= Self.darkMinimumDuration, time >= duration - Self.darkWindow else {
            darkSince = nil
            return nil
        }
        // シークで飛んだら、数え直す
        if let lastTime, abs(time - lastTime) > 2 {
            darkSince = nil
        }
        guard Self.looksLikeCredits(light) else {
            darkSince = nil
            return nil
        }
        let since = darkSince ?? time
        darkSince = since
        return time - since >= Self.darkHold ? since : nil
    }

    /// 黒地に白い文字のような画面か（暗く、色が薄い）
    static func looksLikeCredits(_ light: ScreenLight) -> Bool {
        let levels = [light.left, light.center, light.right].map(luminance)
        let average = levels.reduce(0, +) / 3
        guard average < darkLevel, levels.allSatisfy({ $0 < darkLevel * 2 }) else {
            return false
        }
        let color = light.average
        let top = color.max()
        // ほとんど真っ黒なら、色は見ない
        return top < 0.004 || (top - color.min()) / top < neutralChroma
    }

    static func luminance(_ color: SIMD3<Float>) -> Float {
        0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
    }
}
