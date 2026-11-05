//
//  YouTubeVideoClock.swift
//  TheaterPlayer
//
//  デバッグ用（デバッグのビルドだけ）：YouTube のページの <video> の時計。ページは 0.25 秒ごとと、再生・一時停止・シークなどのたびに、
//  そのときの currentTime と時刻（1970 年からの秒）を知らせる。あいだの時刻は、速さから進める。
//  知らせの currentTime は少し揺れるので、予想との差が小さいときは少しだけ寄せる（鳴らす位置が揺れないように）。
//

#if DEBUG
nonisolated struct YouTubeVideoClock: Equatable {
    /// これより小さな差は、少しずつ寄せる（大きければ合わせ直す）
    static let tolerance = 0.03
    /// 小さな差を寄せる割合
    static let smoothing = 0.2

    /// 基準の動画の時刻（秒）と、そのときの時刻（1970 年からの秒）
    private(set) var mediaTime = 0.0
    private(set) var at = 0.0
    private(set) var rate = 1.0
    private(set) var isPlaying = false
    private(set) var hasReport = false

    /// 知らせを受ける。予想との差（秒。合わせ直したときは nil）を返す
    @discardableResult
    mutating func update(mediaTime reported: Double, at time: Double, rate newRate: Double, playing: Bool) -> Double? {
        defer {
            rate = newRate
            isPlaying = playing
            hasReport = true
        }
        if hasReport, isPlaying, playing, newRate == rate {
            let predicted = mediaTime + (time - at) * rate
            let error = reported - predicted
            if abs(error) < Self.tolerance {
                mediaTime = predicted + error * Self.smoothing
                at = time
                return error
            }
        }
        mediaTime = reported
        at = time
        return nil
    }

    /// 時刻 time（1970 年からの秒）の動画の時刻。知らせを受けていなければ nil
    func mediaTime(at time: Double) -> Double? {
        guard hasReport else {
            return nil
        }
        return isPlaying ? mediaTime + (time - at) * rate : mediaTime
    }
}
#endif
