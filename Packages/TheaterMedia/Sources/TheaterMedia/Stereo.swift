//
//  Stereo.swift
//  TheaterMedia
//
//  3D（立体視）の映像の、左右の目の絵の並べ方。
//  左右の目の絵は別々の画素のバッファにして、左目・右目の印（タグ）を付けて 1 つのサンプルにまとめ、RealityKit の VideoMaterial に渡す（VideoOutput）。
//  - 左右・上下に並べた映像（3D の Blu-ray から作った MKV など）は、フレームを左右（上下）に切り分ける
//  - 左右が別の層の映像（iPhone・Vision Pro の空間ビデオ。MV-HEVC）は、両方の層をデコードして、そのまま左右の目の絵にする
//  見分け方：入れ物の立体の情報（MKV の StereoMode・MOV の vexu）→ ファイル名の印（SBS・TAB など）の順。操作パネルでも選べる
//

import CFFmpeg
import CoreVideo
import Foundation

/// 左右の目の絵の並べ方
public enum StereoPacking: String, Sendable, Codable, CaseIterable {
    /// 立体ではない
    case mono
    /// 左右に並べる（左目が左。SBS）
    case sideBySide
    /// 上下に並べる（左目が上。TAB・OU）
    case overUnder
    /// 左右が別の層（MV-HEVC の空間ビデオ。デコードのときに左右に並べる）
    case multiview

    /// 片目の絵の縦横比。frameAspect はフレーム全体の表示の縦横比。
    /// 片目ずつ縮めずに並べた（フル）か、半分に縮めて元の大きさに収めた（ハーフ）かは、フレームの形で見分ける
    public func eyeAspect(frameAspect: Double) -> Double {
        switch self {
        case .sideBySide:
            // フルの左右（16:9 なら 3.56）は半分に、ハーフ（16:9 のまま）はそのまま
            frameAspect >= 2.5 ? frameAspect / 2 : frameAspect
        case .overUnder:
            // フルの上下（16:9 なら 0.89）は 2 倍に、ハーフはそのまま
            frameAspect <= 1.25 ? frameAspect * 2 : frameAspect
        case .mono, .multiview:
            // 空間ビデオの形式（VideoFormat）は片目の層の大きさで分かるので、そのまま
            frameAspect
        }
    }

    /// ファイル名の印から（3D の動画によく付く SBS・HSBS・TAB・HOU・Side-by-Side など）。分からなければ nil
    public static func guess(fromFileName name: String) -> StereoPacking? {
        let lowered = (name as NSString).deletingPathExtension.lowercased()
        let tokens = Set(lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let joined = lowered.filter { $0.isLetter || $0.isNumber }
        let sideBySide: Set<String> = ["sbs", "hsbs", "fsbs", "halfsbs", "fullsbs", "3dsbs"]
        let overUnder: Set<String> = ["tab", "htab", "ftab", "ou", "hou", "fou", "halfou", "fullou", "3dtab", "3dou"]
        if !tokens.isDisjoint(with: sideBySide) || joined.contains("sidebyside") {
            return .sideBySide
        }
        if !tokens.isDisjoint(with: overUnder) || joined.contains("topbottom") || joined.contains("topandbottom")
            || joined.contains("overunder") {
            return .overUnder
        }
        return nil
    }
}

/// 利用者の選び方（操作パネルの「3D」）
public enum StereoMode: String, Sendable, Codable, CaseIterable {
    /// 入れ物の立体の情報・ファイル名から決める
    case auto
    /// 立体にしない（空間ビデオは片目だけ）
    case off
    case sideBySide
    case overUnder

    /// 映すときの並べ方。track は入れ物の立体の情報、fileName は開いたファイルの名前
    public func resolve(track: StereoPacking, fileName: String) -> StereoPacking {
        switch self {
        case .auto:
            track != .mono ? track : StereoPacking.guess(fromFileName: fileName) ?? .mono
        case .off:
            .mono
        case .sideBySide:
            .sideBySide
        case .overUnder:
            .overUnder
        }
    }
}

/// 空間ビデオ（MV-HEVC）の、同じ時刻の左右の目のコマを組にする（デコードのスレッドだけが使う）
final class StereoViewPairer {
    /// 組の相手を待っている片目のコマ（同じ時刻のもう片方が来たら組にする）
    private var pending: UnsafeMutablePointer<AVFrame>?
    private var pendingIsLeft = true
    private let maker = PixelBufferMaker()

    deinit {
        reset()
    }

    /// 待っているコマを捨てる（シークのとき）
    func reset() {
        var frame = pending
        av_frame_free(&frame)
        pending = nil
    }

    /// 片目のコマを受け取る。同じ時刻の左右がそろったら、左目・右目の画素のバッファを返す
    func add(_ view: UnsafeMutablePointer<AVFrame>) -> (left: CVPixelBuffer, right: CVPixelBuffer)? {
        let isLeft = Self.isLeftEye(view)
        if let waiting = pending, waiting.pointee.pts == view.pointee.pts, pendingIsLeft != isLeft {
            let (leftFrame, rightFrame) = isLeft ? (view, waiting) : (waiting, view)
            let pair = maker.make(from: leftFrame).flatMap { left in maker.make(from: rightFrame).map { (left, $0) } }
            reset()
            return pair
        }
        // 組にならない（最初の片目・時刻が飛んだ）：今のコマを待つ
        reset()
        pending = av_frame_clone(view)
        pendingIsLeft = isLeft
        return nil
    }

    /// 左目のコマか。FFmpeg がコマに付ける立体の情報（左・右）→ 層の番号（0 が基本の層。空間ビデオでは左目）の順に見る
    static func isLeftEye(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        if let side = av_frame_get_side_data(frame, AV_FRAME_DATA_STEREO3D), let data = side.pointee.data,
           side.pointee.size >= MemoryLayout<AVStereo3D>.size {
            let stereo = UnsafeRawPointer(data).loadUnaligned(as: AVStereo3D.self)
            if stereo.view == AV_STEREO3D_VIEW_LEFT {
                return true
            }
            if stereo.view == AV_STEREO3D_VIEW_RIGHT {
                return false
            }
        }
        if let side = av_frame_get_side_data(frame, AV_FRAME_DATA_VIEW_ID), let data = side.pointee.data, side.pointee.size >= 4 {
            return UnsafeRawPointer(data).loadUnaligned(as: Int32.self) == 0
        }
        return true
    }
}
