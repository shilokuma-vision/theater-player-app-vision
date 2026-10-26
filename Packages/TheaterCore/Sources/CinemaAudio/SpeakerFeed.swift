//
//  SpeakerFeed.swift
//  CinemaAudio
//
//  スピーカー（空間オーディオの音源）1 つに送る信号。系統（L・Lss など）の信号に、倍率と小さな遅延を掛ける。
//  映画館のサラウンドは同じ信号を何台ものスピーカーで鳴らす（アレイ）。同じ信号が重なって音が濁らない（くし形の打ち消しが出ない）よう、
//  スピーカーごとに少しずつ遅らせる（実際の映画館でも、スピーカーとの距離の違いで同じことが起きている）。
//

import Foundation

public struct SpeakerFeed: Sendable, Equatable {
    /// どの系統を鳴らすか（LFE ならサブウーファーの信号）
    public let bus: CinemaBus
    /// 倍率（同じ系統のスピーカーの数で、力の和が 1 台分になるように割る）
    public let gain: Float
    /// 遅延（サンプル）
    public let delayFrames: Int

    public init(bus: CinemaBus, gain: Float, delayFrames: Int) {
        self.bus = bus
        self.gain = gain
        self.delayFrames = delayFrames
    }

    /// スピーカーの系統の並び（音源ごと）から、各スピーカーへの送りを作る
    public static func feeds(for buses: [CinemaBus], sampleRate: Float) -> [SpeakerFeed] {
        var seen: [CinemaBus: Int] = [:]
        let counts = Dictionary(grouping: buses, by: { $0 }).mapValues(\.count)
        // 0〜6 ms をスピーカーごとにずらす（素数に近い間隔で、規則的な重なりを避ける）
        let spread: [Float] = [0, 3.1, 1.3, 4.7, 2.3, 5.9, 0.7, 3.7, 1.9, 5.3]
        return buses.map { bus in
            let order = seen[bus, default: 0]
            seen[bus] = order + 1
            let count = Float(counts[bus] ?? 1)
            let delay = count > 1 ? spread[order % spread.count] / 1000 * sampleRate : 0
            return SpeakerFeed(bus: bus, gain: 1 / count.squareRoot(), delayFrames: Int(delay))
        }
    }
}
