//
//  MediaPlayer+Stereo.swift
//  TheaterMedia
//
//  3D（立体視）の映像の並べ方を決めて、映像の出口（VideoOutput）に伝える。
//

import Foundation

extension MediaPlayer {
    /// 3D の選び方（操作パネルの「3D」）。変えると、今のファイルの並べ方を決め直す
    public var stereoMode: StereoMode {
        get { lock.withLock { stereoModeValue } }
        set {
            lock.withLock { stereoModeValue = newValue }
            applyStereo()
        }
    }

    /// 今のファイルを映す並べ方（開いていなければ mono）
    public var stereo: StereoPacking {
        lock.withLock { stereoValue }
    }

    /// 選び方・入れ物の立体の情報・ファイルの名前から並べ方を決め、映像の出口に伝える
    func applyStereo() {
        let session = currentSession
        let track = session.flatMap { Self.preferredVideo($0.info) }?.stereo ?? .mono
        let (mode, name) = lock.withLock { (stereoModeValue, fileName) }
        let packing = session == nil ? StereoPacking.mono : mode.resolve(track: track, fileName: name)
        lock.withLock { stereoValue = packing }
        videoOutput.stereo = packing.output
    }
}
