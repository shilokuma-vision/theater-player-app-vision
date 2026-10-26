//
//  CinemaBus.swift
//  CinemaAudio
//
//  映画館のスピーカーの系統（7.1.4 のベッド）と、入力のチャンネル（動画・音楽の音声）の対応。
//

/// 映画館のスピーカーの系統
public enum CinemaBus: String, CaseIterable, Sendable, Codable {
    /// スクリーンの裏（左・中央・右）
    case left = "L"
    case center = "C"
    case right = "R"
    /// サブウーファー（低音）
    case lfe = "LFE"
    /// 側壁のサラウンド（前寄り）
    case leftSideSurround = "Lss"
    case rightSideSurround = "Rss"
    /// 後方のサラウンド（側壁の後ろ寄りと、後ろの壁）
    case leftRearSurround = "Lrs"
    case rightRearSurround = "Rrs"
    /// 天井（前寄り・後ろ寄り）
    case leftTopFront = "Ltf"
    case rightTopFront = "Rtf"
    case leftTopRear = "Ltr"
    case rightTopRear = "Rtr"

    /// サラウンド（側壁・後方）
    public var isSurround: Bool {
        [.leftSideSurround, .rightSideSurround, .leftRearSurround, .rightRearSurround].contains(self)
    }

    /// 天井
    public var isTop: Bool {
        [.leftTopFront, .rightTopFront, .leftTopRear, .rightTopRear].contains(self)
    }

    /// 系統の並びでの番号
    public var index: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

/// 入力の音声のチャンネルの役割（FFmpeg の AVChannel に対応）
public enum InputChannel: Sendable, Equatable {
    case frontLeft, frontRight, frontCenter, lowFrequency
    case backLeft, backRight, backCenter
    case sideLeft, sideRight
    case frontLeftOfCenter, frontRightOfCenter
    case wideLeft, wideRight
    case topFrontLeft, topFrontRight, topFrontCenter
    case topBackLeft, topBackRight, topBackCenter
    case topSideLeft, topSideRight, topCenter
    /// 役割の分からないチャンネル（中央に混ぜる）
    case unknown
}

/// 入力のチャンネルを、系統へどれだけ（振幅の倍率）送るか
public struct ChannelMatrix: Sendable {
    /// [入力のチャンネル][系統] の倍率
    public let gains: [[Float]]
    /// ステレオの 2 チャンネル（アップミックスの対象）
    public let isStereo: Bool
    /// 天井の系統に送るチャンネルがあるか
    public let hasHeight: Bool

    public init(layout: [InputChannel]) {
        let busCount = CinemaBus.allCases.count
        var gains = [[Float]](repeating: [Float](repeating: 0, count: busCount), count: layout.count)
        let hasSide = layout.contains(.sideLeft) || layout.contains(.sideRight)
        let hasBack = layout.contains(.backLeft) || layout.contains(.backRight)
        for (index, channel) in layout.enumerated() {
            for (bus, gain) in Self.route(channel, mono: layout.count == 1, hasSide: hasSide, hasBack: hasBack) {
                gains[index][bus.index] += gain
            }
        }
        self.gains = gains
        isStereo = layout == [.frontLeft, .frontRight]
        hasHeight = layout.contains {
            [
                .topFrontLeft, .topFrontRight, .topBackLeft, .topBackRight, .topSideLeft, .topSideRight,
                .topFrontCenter, .topBackCenter, .topCenter
            ].contains($0)
        }
    }

    /// -3 dB（等しい力で 2 か所に分ける）
    static let half: Float = 0.707_106_8

    static func route(_ channel: InputChannel, mono: Bool, hasSide: Bool, hasBack: Bool) -> [(CinemaBus, Float)] {
        switch channel {
        case .frontLeft:
            [(.left, 1)]
        case .frontRight:
            [(.right, 1)]
        case .frontCenter, .unknown:
            [(.center, 1)]
        case .lowFrequency:
            [(.lfe, 1)]
        case .frontLeftOfCenter:
            [(.left, half), (.center, half)]
        case .frontRightOfCenter:
            [(.right, half), (.center, half)]
        case .wideLeft:
            [(.left, half), (.leftSideSurround, half)]
        case .wideRight:
            [(.right, half), (.rightSideSurround, half)]
        default:
            surroundRoute(channel, hasSide: hasSide, hasBack: hasBack) + topRoute(channel)
        }
    }

    /// サラウンド：5.1 の Ls / Rs は側壁と後方の両方へ（映画館の 5.1 の鳴らし方）。7.1 は側方 → 側壁、後方 → 後方
    static func surroundRoute(_ channel: InputChannel, hasSide: Bool, hasBack: Bool) -> [(CinemaBus, Float)] {
        let both = !(hasSide && hasBack)
        switch channel {
        case .sideLeft:
            return both ? [(.leftSideSurround, half), (.leftRearSurround, half)] : [(.leftSideSurround, 1)]
        case .sideRight:
            return both ? [(.rightSideSurround, half), (.rightRearSurround, half)] : [(.rightSideSurround, 1)]
        case .backLeft:
            return both ? [(.leftSideSurround, half), (.leftRearSurround, half)] : [(.leftRearSurround, 1)]
        case .backRight:
            return both ? [(.rightSideSurround, half), (.rightRearSurround, half)] : [(.rightRearSurround, 1)]
        case .backCenter:
            return [(.leftRearSurround, half), (.rightRearSurround, half)]
        default:
            return []
        }
    }

    static func topRoute(_ channel: InputChannel) -> [(CinemaBus, Float)] {
        switch channel {
        case .topFrontLeft:
            [(.leftTopFront, 1)]
        case .topFrontRight:
            [(.rightTopFront, 1)]
        case .topBackLeft:
            [(.leftTopRear, 1)]
        case .topBackRight:
            [(.rightTopRear, 1)]
        case .topSideLeft:
            [(.leftTopFront, half), (.leftTopRear, half)]
        case .topSideRight:
            [(.rightTopFront, half), (.rightTopRear, half)]
        case .topFrontCenter:
            [(.leftTopFront, half), (.rightTopFront, half)]
        case .topBackCenter:
            [(.leftTopRear, half), (.rightTopRear, half)]
        case .topCenter:
            [(.leftTopFront, 0.5), (.rightTopFront, 0.5), (.leftTopRear, 0.5), (.rightTopRear, 0.5)]
        default:
            []
        }
    }
}
