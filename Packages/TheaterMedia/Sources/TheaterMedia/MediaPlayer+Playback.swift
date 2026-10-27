//
//  MediaPlayer+Playback.swift
//  TheaterMedia
//
//  再生・一時停止・シーク・速さと、時計（音の時計に映像の時計を合わせる）。
//

import CinemaAudio
import Darwin
import Foundation

extension MediaPlayer {
    // MARK: - 再生の操作

    public func play() {
        controlLock.withLock {
            guard let session = currentSession else {
                return
            }
            switch state {
            case .ended:
                // 頭から。シークの後、データがそろってから鳴らし始める（startIfReady）
                seek(to: 0)
            case .paused:
                session.control.isPaused = false
                // シークの直後などで、今の位置の音がまだそろっていなければ、そろってから鳴らす
                if !startIfReady(session) {
                    setState(.buffering)
                }
            default:
                break
            }
        }
    }

    public func pause() {
        controlLock.withLock {
            guard let session = currentSession, state == .playing || state == .buffering else {
                return
            }
            let time = currentTime
            session.control.isPaused = true
            ring.setPaused(true)
            videoOutput.setRate(0, time: time)
            lock.lock()
            pausedTime = time
            lock.unlock()
            setState(.paused)
        }
    }

    /// time（秒）へ移る。再生中なら、データがそろってから続ける
    public func seek(to time: Double) {
        controlLock.withLock {
            guard let session = currentSession else {
                return
            }
            let target = max(0, min(time, (session.info.duration ?? .infinity) - 0.05))
            _ = session.requestSeek(to: target)
            // ファイルの中の字幕は読み直すので消す。別のファイルの字幕は読み直さないので残す
            if !lock.withLock({ showsExternalSubtitles }) {
                subtitleStore.clear()
            }
            // 前の位置の音の時刻の対応は使わない（新しい区間の音が入ったら決め直す）
            audioTimeline.reset()
            lock.lock()
            pausedTime = target
            audioStarved = false
            lock.unlock()
            videoOutput.setRate(0, time: target)
            if state == .playing || state == .ended {
                ring.setPaused(true)
                session.control.isPaused = false
                setState(.buffering)
            }
        }
    }

    /// 再生の速さ（0.5〜2.0。音は高さを変えずに速さだけ変える）
    public var rate: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return rateValue
        }
        set {
            controlLock.withLock {
                let clamped = max(0.5, min(newValue, 2))
                lock.lock()
                rateValue = clamped
                lock.unlock()
                currentSession?.audio?.playbackRate = Double(clamped)
                // 音の時刻の対応（1 サンプルで進む時刻）が変わるので、今の位置から鳴らし直す
                if currentSession?.audio != nil {
                    seek(to: currentTime)
                } else if state == .playing {
                    videoOutput.setRate(clamped, time: currentTime)
                }
            }
        }
    }

    var currentSession: PlaybackSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    /// 音の遅れの調整（秒。正なら音を遅らせる）
    public var audioDelay: Double {
        get { timing.audioDelay }
        set { updateTiming { $0.audioDelay = newValue } }
    }

    /// 字幕の遅れの調整（秒。正なら字幕を遅らせる）
    public var subtitleDelay: Double {
        get { timing.subtitleDelay }
        set { updateTiming { $0.subtitleDelay = newValue } }
    }

    var timing: PlayerTiming {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    private func updateTiming(_ change: (inout PlayerTiming) -> Void) {
        lock.lock()
        change(&settings)
        lock.unlock()
    }

    // MARK: - 時刻

    /// いまの再生の位置（秒）
    public var currentTime: Double {
        switch state {
        case .playing:
            audioClock() ?? videoOutput.time
        default:
            lock.withLock { pausedTime }
        }
    }

    /// 長さ（秒）
    public var duration: Double? {
        currentSession?.info.duration
    }

    /// 音の時計：ring が最後に鳴らした位置の時刻 + そこからの経過 − 出力の遅れ + 利用者の遅れの調整。
    /// 音を鳴らし終えた・音のデータが来ないときは nil（映像の時計で進める）
    func audioClock() -> Double? {
        guard let session = currentSession, session.audio != nil, !isAudioSilent(session),
              let render = ring.lastRender(), render.hostTime == 0 || render.hostTime >= lock.withLock({ ringStartHost }),
              let mediaTime = audioTimeline.time(atRingIndex: render.index, serial: session.control.serial) else {
            return nil
        }
        let elapsed = min(HostClock.seconds(from: render.hostTime, to: mach_absolute_time()), 0.2)
        let timing = timing
        // 出力の遅れは実際の時間なので速さを掛ける。音を遅らせる（正）なら、同じ音のときに映像を先へ進める
        return mediaTime + (elapsed - timing.audioOutputLatency) * Double(rate) + timing.audioDelay
    }

    /// 音が鳴っていない：最後まで鳴らし終えた、またはデータが来ず待っても進まない
    private func isAudioSilent(_ session: PlaybackSession) -> Bool {
        (ring.pendingFrames < 256 && session.control.hasEnded(.audio)) || lock.withLock { audioStarved }
    }

    /// 表示中の映像の時刻（スクリーンの光・字幕に使う）
    public var displayTime: Double {
        videoOutput.time
    }

    /// 表示中のフレームのスクリーンの光
    public func screenLight() -> ScreenLight? {
        lights.light(at: videoOutput.time)
    }

    /// 今の時刻の字幕
    public func subtitles(at time: Double) -> [SubtitleCue] {
        subtitleStore.cues(at: time - timing.subtitleDelay)
    }

    // MARK: - 時計のスレッド

    func startClock() {
        let thread = Thread { [weak self] in
            while !Thread.current.isCancelled {
                Thread.sleep(forTimeInterval: 0.02)
                self?.tick()
            }
        }
        thread.name = "TheaterMedia.clock"
        thread.qualityOfService = .userInitiated
        lock.lock()
        clockThread = thread
        lock.unlock()
        thread.start()
    }

    private func tick() {
        controlLock.withLock {
            guard let session = currentSession else {
                return
            }
            switch state {
            case .playing:
                updateAudioStarved(session)
                if let audioTime = audioClock() {
                    follow(audioTime)
                } else if videoOutput.rate != rate {
                    // 音の時計が無い：映像の時計で進める（ずれを詰めるための速さの調整を戻す）
                    videoOutput.adjustRate(rate)
                }
                if session.control.isFinished(hasVideo: session.video != nil, hasAudio: session.audio != nil), ring.pendingFrames < 256 {
                    finish()
                }
            case .buffering:
                startIfReady(session)
            default:
                break
            }
        }
    }

    /// 映像の時計を音の時計に合わせる。大きくずれたら合わせ直し、小さなずれは速さを少し変えて詰める
    private func follow(_ audioTime: Double) {
        let difference = audioTime - videoOutput.time
        if abs(difference) > 0.15 {
            videoOutput.setRate(rate, time: audioTime)
        } else {
            let correction = Float(max(-0.03, min(0.03, difference * 0.4)))
            videoOutput.adjustRate(rate * (1 + correction))
        }
    }

    /// 音が尽き、映像の待ち行列がいっぱいで読み込みが止まった（音の無い所）：音を待つと進まないので映像の時計で進める。
    /// 音がまたたまったら音の時計に戻す
    private func updateAudioStarved(_ session: PlaybackSession) {
        let pending = ring.pendingFrames
        let starving = pending < 256 && session.isStarvingAudio
        lock.withLock {
            if starving {
                audioStarved = true
            } else if pending > 12_000 {
                audioStarved = false
            }
        }
    }

    /// データがそろっていれば鳴らし始める（シークの後・再生を始めるとき）。始めたら true
    @discardableResult
    private func startIfReady(_ session: PlaybackSession) -> Bool {
        let target = lock.withLock { pausedTime }
        var start = target
        if session.audio != nil {
            let base = audioTimeline.current.flatMap { $0.serial == session.control.serial ? $0 : nil }
            // 音の区間が決まり、0.25 秒分たまったら鳴らし始める。音が最後まで出た（シーク先の後に音が少ない・無い）、
            // 音のパケットが来ない（音の無い所）なら、たまるのを待たない
            guard (base != nil && ring.pendingFrames > 12_000) || session.control.hasEnded(.audio) || session.isStarvingAudio else {
                return false
            }
            if let base {
                start = max(base.time, target)
            }
            lock.withLock { ringStartHost = mach_absolute_time() }
            ring.setPaused(false)
        }
        videoOutput.setRate(rate, time: start)
        setState(.playing)
        return true
    }

    private func finish() {
        let time = currentTime
        ring.setPaused(true)
        videoOutput.setRate(0, time: time)
        lock.lock()
        pausedTime = time
        lock.unlock()
        currentSession?.control.isPaused = true
        setState(.ended)
    }
}

/// ホストの時計（mach_absolute_time）
enum HostClock {
    static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? Double(end - start) / ticksPerSecond : -Double(start - end) / ticksPerSecond
    }
}
