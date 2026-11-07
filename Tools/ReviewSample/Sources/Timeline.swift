//
//  Timeline.swift
//  ReviewSample
//
//  サンプルの動画の構成（チャプター）と、映画館のスピーカー（5.1）。
//  5 分以上にするのは、映画館の開演の流れ（ブザー・客電・幕）が 5 分以上の動画でだけ動くため。
//  エンドロールのチャプター（End Credits）は、作品の後半に置く（アプリの CreditsFinder がチャプターの名前で見つける）。
//

import Foundation

/// 動画の 1 つの区切り（チャプター）
enum Part: Int, CaseIterable {
    case title
    case countdown
    case bars
    case speakers
    case around
    case music
    case credits

    /// チャプターの名前
    var name: String {
        switch self {
        case .title: "Title"
        case .countdown: "Countdown"
        case .bars: "Color Bars and 1 kHz Tone"
        case .speakers: "Speaker Check (5.1)"
        case .around: "Around the Theater"
        case .music: "Ambient Music"
        case .credits: "End Credits"
        }
    }

    /// 長さ（秒）
    var length: Double {
        switch self {
        case .title: 8
        case .countdown: 10
        case .bars: 12
        case .speakers: 36
        case .around: 24
        case .music: 150
        case .credits: 80
        }
    }

    /// 始まり（秒）
    var start: Double {
        Part.allCases.prefix(while: { $0 != self }).reduce(0) { $0 + $1.length }
    }

    /// 動画の長さ（秒）
    static let duration = allCases.reduce(0) { $0 + $1.length }

    /// その時刻の区切りと、区切りの中での時刻
    static func at(_ time: Double) -> (part: Part, local: Double) {
        let part = allCases.last { $0.start <= time } ?? .title
        return (part, time - part.start)
    }
}

/// 5.1 のスピーカー。rawValue は音声のチャンネルの順（L・R・C・LFE・Ls・Rs。kAudioChannelLayoutTag_MPEG_5_1_A）
enum Speaker: Int, CaseIterable {
    case left
    case right
    case center
    case lfe
    case leftSurround
    case rightSurround

    /// 正面から右回りの角度（度）。LFE は向きを持たない
    var angle: Double? {
        switch self {
        case .left: 330
        case .right: 30
        case .center: 0
        case .lfe: nil
        case .leftSurround: 250
        case .rightSurround: 110
        }
    }

    var name: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .center: "Center"
        case .lfe: "Subwoofer (LFE)"
        case .leftSurround: "Left Surround"
        case .rightSurround: "Right Surround"
        }
    }

    var shortName: String {
        switch self {
        case .left: "L"
        case .right: "R"
        case .center: "C"
        case .lfe: "LFE"
        case .leftSurround: "Ls"
        case .rightSurround: "Rs"
        }
    }

    /// スピーカーの確認で鳴らす順（前の左から右回り、最後にサブウーファー）
    static let checkOrder: [Speaker] = [.left, .center, .right, .rightSurround, .leftSurround, .lfe]

    /// スピーカーの確認で、1 台を鳴らす長さ（秒）
    static let checkLength: Double = 6

    /// スピーカーの確認で、その時刻に鳴らしているスピーカーと、パルスが鳴っているか（0.75 秒鳴らして 0.25 秒休む）
    static func check(at local: Double) -> (speaker: Speaker, isOn: Bool) {
        let index = min(Int(local / checkLength), checkOrder.count - 1)
        let within = local - Double(index) * checkLength
        let isOn = within < checkLength - 0.25 && within.truncatingRemainder(dividingBy: 1) < 0.75
        return (checkOrder[index], isOn)
    }

    /// 映画館をひと回りする音の角度（度）。12 秒で 1 周し、2 周する
    static func aroundAngle(at local: Double) -> Double {
        (local / 12 * 360).truncatingRemainder(dividingBy: 360)
    }

    /// その角度の音を、隣り合う 2 台のスピーカーに振り分ける（音の強さを保つ）
    static func panGains(angle: Double) -> [Speaker: Double] {
        let ring = allCases.compactMap { speaker in speaker.angle.map { (speaker, $0) } }.sorted { $0.1 < $1.1 }
        for (index, current) in ring.enumerated() {
            let next = ring[(index + 1) % ring.count]
            let end = next.1 > current.1 ? next.1 : next.1 + 360
            let target = angle < current.1 ? angle + 360 : angle
            guard target >= current.1, target < end else {
                continue
            }
            let position = (target - current.1) / (end - current.1)
            return [current.0: cos(position * .pi / 2), next.0: sin(position * .pi / 2)]
        }
        return [.center: 1]
    }
}
