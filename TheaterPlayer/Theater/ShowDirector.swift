//
//  ShowDirector.swift
//  TheaterPlayer
//
//  上映の進行。再生を「上映」として進め、客電・マスキング（幕）の段階を決める。
//

import Foundation

/// 上映の段階。客電の行き先（LightingDirector）を決める
enum ShowPhase: Equatable {
    /// 開場：何も開いていない・止めている（一時停止を含む）
    case lobby
    /// 本編（静止画を出しているときも）
    case feature
}
