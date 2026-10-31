//
//  UnitFormatTests.swift
//  TheaterPlayerTests
//
//  数と単位の書き方が、Locale（英語・日本語）に合うか。
//

import Foundation
import Testing
@testable import TheaterPlayer

struct UnitFormatTests {
    static let english = Locale(identifier: "en_US")
    static let japanese = Locale(identifier: "ja_JP")
    static let french = Locale(identifier: "fr_FR")

    @Test func percent() {
        #expect(UnitFormat.percent(0.5, locale: Self.english) == "50%")
        #expect(UnitFormat.percent(1.234, locale: Self.japanese) == "123%")
        // フランス語は数と % のあいだを空ける（狭い空白）
        #expect(UnitFormat.percent(0.5, locale: Self.french) != "50%")
    }

    /// 音・字幕のずれ：0 にも符号を付け、小数 2 桁で、秒の単位は言語の書き方にする
    @Test func signedSeconds() {
        #expect(UnitFormat.signedSeconds(0.05, locale: Self.english) == "+0.05 sec")
        #expect(UnitFormat.signedSeconds(-0.1, locale: Self.english) == "-0.10 sec")
        #expect(UnitFormat.signedSeconds(0, locale: Self.japanese) == "+0.00秒")
        #expect(UnitFormat.signedSeconds(0.05, locale: Self.french).hasPrefix("+0,05"))
    }

    /// サンプリング周波数：小数は 1 桁まで（44.1 kHz）。割り切れるときは小数を付けない
    @Test func sampleRate() {
        #expect(UnitFormat.sampleRate(44_100, locale: Self.english) == "44.1 kHz")
        #expect(UnitFormat.sampleRate(48_000, locale: Self.japanese) == "48 kHz")
        #expect(UnitFormat.sampleRate(44_100, locale: Self.french).hasPrefix("44,1"))
    }

    /// 速さ・dB：数の書き方は Locale に合わせ、単位の付け方（1.25× / 1.25 倍）は訳で決める
    @Test func rateAndDecibels() {
        #expect(UnitFormat.rate(1.25, locale: Self.english).hasPrefix("1.25"))
        #expect(UnitFormat.rate(0.5, locale: Self.english).hasPrefix("0.5"))
        #expect(UnitFormat.rate(1.25, locale: Self.french).hasPrefix("1,25"))
        #expect(UnitFormat.decibels(6, locale: Self.english).hasPrefix("+6"))
        #expect(UnitFormat.decibels(0, locale: Self.english).hasPrefix("+0"))
        #expect(UnitFormat.decibels(6, locale: Self.english).hasSuffix("dB"))
    }
}
