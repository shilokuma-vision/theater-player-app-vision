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

    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else {
            return
        }
        FileHandle.standardError.write(Data("[TheaterPlayer] \(message())\n".utf8))
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
