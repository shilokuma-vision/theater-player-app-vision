//
//  Diagnostics.swift
//  TheaterMedia
//
//  実機で再生の様子を調べるためのログ。起動の引数に -tp-diagnostics を付けたときだけ、標準エラーに書く
//  （xcrun devicectl device process launch --console … jp.shilokuma.TheaterPlayer -- -tp-diagnostics で読める。-- が無いと devicectl が自分の引数と取り違える）。
//

import Foundation
import Synchronization

public enum Diagnostics {
    public static let enabled = ProcessInfo.processInfo.arguments.contains("-tp-diagnostics")
    /// 調べるための切り替え（-tp-fresh-renderer）：スクリーンをつなぐたびに renderer を作り直す
    static let freshRenderer = ProcessInfo.processInfo.arguments.contains("-tp-fresh-renderer")

    /// 行の頭に、起動してからの秒（systemUptime）を付ける（スレッドをまたいだ出来事の前後を見る）
    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else {
            return
        }
        let time = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[TheaterPlayer] \(time) \(message())\n".utf8))
    }

    /// 物を見分ける短い名前（アドレスの下の桁）。renderer・VideoMaterial・エンティティが同じ物かをログで見る
    public static func id(_ object: AnyObject?) -> String {
        guard let object else {
            return "なし"
        }
        return String(String(UInt(bitPattern: ObjectIdentifier(object).hashValue), radix: 16).suffix(6))
    }
}

/// 映像のデコードの数（診断用）
struct VideoStats: Sendable {
    var decoded = 0
    var enqueued = 0
    var droppedBeforeSeekTarget = 0
    var droppedLate = 0
    var noPixelBuffer = 0
    var lastFrameTime = Double.nan
    var usesVideoToolbox = false
}
