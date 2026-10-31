//
//  UnitFormat.swift
//  TheaterPlayer
//
//  数と単位の書き方（割合・dB・秒・速さ・周波数）。小数点・桁・単位の書き方を、利用者の Locale に合わせる。
//

import Foundation

nonisolated enum UnitFormat {
    /// 割合（0.5 → 50%）
    static func percent(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// 符号つきの dB（6 → +6 dB）
    static func decibels(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always()).locale(locale))
        return String(localized: "\(number) dB", comment: "Loudness in decibels. The number has a sign, such as +6.")
    }

    /// 符号つきの秒（0.05 → +0.05 sec）。音・字幕のずれ
    static func signedSeconds(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let number = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2)).sign(strategy: .always())
        return Measurement(value: value, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: number).locale(locale))
    }

    /// 再生の速さ（1.25 → 1.25×）
    static func rate(_ value: Float, locale: Locale = .autoupdatingCurrent) -> String {
        let number = Double(value).formatted(.number.precision(.fractionLength(0...2)).locale(locale))
        return String(localized: "\(number)×", comment: "Playback speed, such as 1.5×.")
    }

    /// 音声のサンプリング周波数（44100 → 44.1 kHz）
    static func sampleRate(_ hertz: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let number = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        return Measurement(value: Double(hertz), unit: UnitFrequency.hertz)
            .converted(to: .kilohertz)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: number).locale(locale))
    }
}
