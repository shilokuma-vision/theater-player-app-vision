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
        guard let session = currentSession, state == .paused || state == .ended else {
            return
        }
        if state == .ended {
            seek(to: 0)
        }
        session.control.isPaused = false
        let time = currentTime
        ring.setPaused(false)
        videoOutput.setRate(rate, time: time)
        setState(.playing)
    }

    public func pause() {
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

    /// time（秒）へ移る。再生中なら、データがそろってから続ける
    public func seek(to time: Double) {
        guard let session = currentSession else {
            return
        }
        let target = max(0, min(time, (session.info.duration ?? .infinity) - 0.05))
        _ = session.requestSeek(to: target)
        subtitleStore.clear()
        lock.lock()
        pausedTime = target
        lock.unlock()
        videoOutput.setRate(0, time: target)
        if state == .playing || state == .ended {
            ring.setPaused(true)
            session.control.isPaused = false
            setState(.buffering)
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

    /// 音の時計：ring が最後に鳴らした位置の時刻 + そこからの経過 − 出力の遅れ − 利用者の遅れの調整
    func audioClock() -> Double? {
        guard currentSession?.audio != nil, let render = ring.lastRender(),
              let mediaTime = audioTimeline.time(atRingIndex: render.index) else {
            return nil
        }
        let elapsed = min(HostClock.seconds(from: render.hostTime, to: mach_absolute_time()), 0.2)
        let timing = timing
        return mediaTime + elapsed * Double(rate) - timing.audioOutputLatency - timing.audioDelay
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
        guard let session = currentSession else {
            return
        }
        switch state {
        case .playing:
            if let audioTime = audioClock() {
                follow(audioTime)
            }
            if session.control.isFinished(hasVideo: session.video != nil, hasAudio: session.audio != nil), ring.pendingFrames < 256 {
                finish()
            }
        case .buffering:
            resumeIfReady(session)
        default:
            break
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

    /// シークの後、データがそろったら再生を続ける
    private func resumeIfReady(_ session: PlaybackSession) {
        let target = lock.withLock { pausedTime }
        if session.audio != nil {
            // 音の区間が決まり、0.25 秒分たまったら鳴らし始める
            guard let base = audioTimeline.current, ring.pendingFrames > 12_000 else {
                return
            }
            ring.setPaused(false)
            videoOutput.setRate(rate, time: max(base.time, target))
        } else {
            videoOutput.setRate(rate, time: target)
        }
        setState(.playing)
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
