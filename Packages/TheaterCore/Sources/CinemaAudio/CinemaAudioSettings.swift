//
//  CinemaAudioSettings.swift
//  CinemaAudio
//
//  映画館の音響の設定（アプリの「音響」の画面で変える）。
//

import Foundation

public struct CinemaAudioSettings: Sendable, Equatable, Codable {
    /// ステレオの広げ方
    public enum Upmix: String, Sendable, Codable, CaseIterable {
        /// ステレオのまま（スクリーンの左右だけ）
        case off
        /// 映画館向けに広げる（台詞をセンター、残響・環境音をサラウンドへ）
        case cinema
    }

    /// 音量の幅
    public enum DynamicRange: String, Sendable, Codable, CaseIterable {
        /// 映画館のまま（調整しない）
        case cinema
        /// 少し抑える
        case standard
        /// 夜（大きな音を強く抑え、小さな音と台詞を持ち上げる）
        case night

        /// コンプレッサーの特性
        var curve: CompressorCurve? {
            switch self {
            case .cinema:
                nil
            case .standard:
                CompressorCurve(threshold: -26, ratio: 2, makeup: 2)
            case .night:
                CompressorCurve(threshold: -36, ratio: 4, makeup: 7)
            }
        }
    }

    public var upmix: Upmix = .cinema
    /// センターに分ける強さ（0〜1）
    public var centerAmount: Float = 0.7
    /// サラウンドに分ける強さ（0〜1）
    public var ambienceAmount: Float = 0.6
    /// 天井のスピーカーが無い音声のとき、サラウンドを天井にも少し鳴らす（0〜0.5）
    public var heightAmount: Float = 0.2
    /// 低音の量（dB、60 Hz より下を持ち上げる。0〜12）
    public var bassBoostDB: Float = 4
    /// 低音の残響（0〜1）
    public var rumble: Float = 0.35
    /// 体感の低音（倍音で低音を感じやすくする。0〜1）
    public var virtualBass: Float = 0.5
    /// LFE（.1）の大きさ（映画館の決まりは +10 dB）
    public var lfeGainDB: Float = 10
    /// 低音をサブウーファーへ分ける周波数（Hz）
    public var crossoverHz: Float = 80
    public var dynamicRange: DynamicRange = .cinema
    /// 台詞（センター）を持ち上げる量（dB）
    public var dialogueBoostDB: Float = 0

    public init() {}
}

/// コンプレッサーの特性（threshold は dBFS、ratio は比、makeup は dB）
struct CompressorCurve: Sendable {
    let threshold: Float
    let ratio: Float
    let makeup: Float
}
