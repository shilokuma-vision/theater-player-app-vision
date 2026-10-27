//
//  PlaybackControl.swift
//  TheaterMedia
//
//  読み込み・映像・音声のスレッドが共有する再生の制御（シークの番号・シーク先・止める印）。
//

import Foundation
import Synchronization

final class PlaybackControl: @unchecked Sendable {
    /// シークのたびに増える番号。古い番号のパケット・フレームは捨てる
    private let serialValue = Atomic<Int>(0)
    private let stoppedValue = Atomic<Bool>(false)
    private let state = Mutex(SharedState())

    private struct SharedState {
        /// 正確なシーク：この時刻より前のフレーム・音は捨てる（番号ごと）
        var seekTarget: (serial: Int, time: Double)?
        var paused = true
        /// 読み込みがファイルの終わりに着いた（番号ごと）
        var demuxEnded: Int?
        var videoEnded: Int?
        var audioEnded: Int?
    }

    var serial: Int {
        serialValue.load(ordering: .acquiring)
    }

    var isStopped: Bool {
        stoppedValue.load(ordering: .acquiring)
    }

    func stop() {
        stoppedValue.store(true, ordering: .releasing)
    }

    /// シークを始める。新しい番号を返す
    func beginSeek(to time: Double) -> Int {
        let next = serialValue.add(1, ordering: .acquiringAndReleasing).newValue
        state.withLock { shared in
            shared.seekTarget = (next, time)
            shared.demuxEnded = nil
            shared.videoEnded = nil
            shared.audioEnded = nil
        }
        return next
    }

    /// 番号 serial のシーク先（その番号でなければ nil）
    func seekTarget(for serial: Int) -> Double? {
        state.withLock { shared in
            guard let target = shared.seekTarget, target.serial == serial else {
                return nil
            }
            return target.time
        }
    }

    var isPaused: Bool {
        get { state.withLock { $0.paused } }
        set { state.withLock { $0.paused = newValue } }
    }

    // MARK: - 終わり

    enum Track {
        case demux, video, audio
    }

    func markEnded(_ track: Track, serial: Int) {
        state.withLock { shared in
            switch track {
            case .demux:
                shared.demuxEnded = serial
            case .video:
                shared.videoEnded = serial
            case .audio:
                shared.audioEnded = serial
            }
        }
    }

    /// track が、今の番号で最後まで出たか
    func hasEnded(_ track: Track) -> Bool {
        let current = serial
        return state.withLock { shared in
            switch track {
            case .demux:
                shared.demuxEnded == current
            case .video:
                shared.videoEnded == current
            case .audio:
                shared.audioEnded == current
            }
        }
    }

    /// 映像・音声（あるものだけ）が、今の番号で最後まで出たか
    func isFinished(hasVideo: Bool, hasAudio: Bool) -> Bool {
        let current = serial
        return state.withLock { shared in
            shared.demuxEnded == current && (!hasVideo || shared.videoEnded == current) && (!hasAudio || shared.audioEnded == current)
        }
    }
}
