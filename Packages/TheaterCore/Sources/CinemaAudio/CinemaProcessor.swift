//
//  CinemaProcessor.swift
//  CinemaAudio
//
//  映画館の音響の処理の本体。デコードした音声（チャンネルごとの float、48 kHz）を、スピーカー（空間オーディオの音源）ごとの信号にする。
//
//    入力 → 系統（7.1.4）へ振り分け（ステレオは映画館向けに広げる）→ 天井へ少し回す → 台詞の持ち上げ
//         → ベースマネジメント（低域をサブウーファーへ）→ 低音の量・残響・体感の低音 → 音量の幅の調整
//         → スピーカーごとの倍率と遅延 → リミッター → 出力
//
//  1 つのスレッド（音声のデコードのスレッド）から process を呼ぶ。settings は別のスレッドから書き換えてよい。
//

import Foundation
import Synchronization

public final class CinemaProcessor: @unchecked Sendable {
    public let sampleRate: Float
    public let feeds: [SpeakerFeed]
    /// 出力が入力から遅れる量（サンプル）。音と映像を合わせるのに使う
    public static let latencyFrames = StereoUpmixer.latency + LookaheadLimiter.lookahead
    private let maxFrames: Int
    private let pendingSettings = Mutex(CinemaAudioSettings())
    private var settings = CinemaAudioSettings()
    private var matrix = ChannelMatrix(layout: [.frontLeft, .frontRight])
    private let buses: PlanarBuffer
    private let sub: PlanarBuffer
    private var state: ProcessorState

    /// feeds：スピーカーの系統の並び（音源の順）
    public init(speakers: [CinemaBus], sampleRate: Float = 48_000, maxFrames: Int = 4096) throws {
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        feeds = SpeakerFeed.feeds(for: speakers, sampleRate: sampleRate)
        buses = PlanarBuffer(channels: CinemaBus.allCases.count, frames: maxFrames)
        sub = PlanarBuffer(channels: 2, frames: maxFrames)
        state = try ProcessorState(settings: CinemaAudioSettings(), feeds: feeds, sampleRate: sampleRate, maxFrames: maxFrames)
    }

    /// 設定を変える（次の処理から効く）
    public func update(settings newSettings: CinemaAudioSettings) {
        pendingSettings.withLock { $0 = newSettings }
    }

    /// 入力のチャンネルの並びを変える（ファイル・音声トラックを開いたとき）
    public func configure(input layout: [InputChannel]) {
        matrix = ChannelMatrix(layout: layout)
        reset()
    }

    /// 途中の音を捨てる（シークのとき）
    public func reset() {
        state.reset()
    }

    /// input：入力のチャンネルごとの frames サンプル。output：スピーカーごとの frames サンプル（feeds の順）
    public func process(input: [UnsafePointer<Float>], frames: Int, output: [UnsafeMutablePointer<Float>]) {
        var offset = 0
        while offset < frames {
            let chunk = min(maxFrames, frames - offset)
            processChunk(input: input.map { $0 + offset }, frames: chunk, output: output.map { $0 + offset })
            offset += chunk
        }
    }

    private func processChunk(input: [UnsafePointer<Float>], frames: Int, output: [UnsafeMutablePointer<Float>]) {
        let latest = pendingSettings.withLock { $0 }
        if latest != settings {
            state.apply(latest, previous: settings, sampleRate: sampleRate)
            settings = latest
        }
        buses.clear(frames: frames)
        if matrix.isStereo && settings.upmix == .cinema {
            upmix(input: input, frames: frames)
        } else {
            mix(input: input, frames: frames)
        }
        addHeight(frames: frames)
        scaleCenter(frames: frames)
        state.bass.process(buses: buses.channels, sub: sub.channels[0], frames: frames, lfeGain: pow(10, settings.lfeGainDB / 20))
        state.lowFrequency(sub: sub.channels[0], harmonics: sub.channels[1], frames: frames, settings: settings)
        applyDynamics(frames: frames)
        writeFeeds(output: output, frames: frames)
        state.limiter.process(output, frames: frames)
    }

    // MARK: - 振り分け

    private func mix(input: [UnsafePointer<Float>], frames: Int) {
        for (channel, gains) in matrix.gains.enumerated() where channel < input.count {
            for (bus, gain) in gains.enumerated() where gain != 0 {
                let target = buses.channels[bus]
                let source = input[channel]
                for frame in 0..<frames {
                    target[frame] += source[frame] * gain
                }
            }
        }
        // アップミックスと同じだけ遅らせる（どちらでも音と映像のずれが変わらないように）
        for bus in 0..<buses.channels.count {
            let target = buses.channels[bus]
            for frame in 0..<frames {
                target[frame] = state.alignment[bus].process(target[frame])
            }
        }
    }

    private func upmix(input: [UnsafePointer<Float>], frames: Int) {
        let channels = buses.channels
        let surroundLeft = state.scratch.channels[0]
        let surroundRight = state.scratch.channels[1]
        state.upmixer.centerAmount = settings.centerAmount
        state.upmixer.ambienceAmount = settings.ambienceAmount
        state.upmixer.process(
            left: input[0],
            right: input[min(1, input.count - 1)],
            count: frames,
            outputs: [
                channels[CinemaBus.left.index],
                channels[CinemaBus.right.index],
                channels[CinemaBus.center.index],
                surroundLeft,
                surroundRight
            ]
        )
        // サラウンドは少し遅らせ、高域を落とす（前の音が後ろから聞こえないように）。側壁と後方の両方へ
        for frame in 0..<frames {
            let left = state.surroundFilters[0].process(state.surroundDelays[0].process(surroundLeft[frame])) * ChannelMatrix.half
            let right = state.surroundFilters[1].process(state.surroundDelays[1].process(surroundRight[frame])) * ChannelMatrix.half
            channels[CinemaBus.leftSideSurround.index][frame] = left
            channels[CinemaBus.leftRearSurround.index][frame] = left
            channels[CinemaBus.rightSideSurround.index][frame] = right
            channels[CinemaBus.rightRearSurround.index][frame] = right
        }
    }

    /// 天井の系統が無い音声のとき、サラウンドの中高域を天井にも少し鳴らす（包まれる感じを足す）
    private func addHeight(frames: Int) {
        guard !matrix.hasHeight, settings.heightAmount > 0 else {
            return
        }
        let pairs: [(CinemaBus, CinemaBus)] = [
            (.leftSideSurround, .leftTopFront), (.rightSideSurround, .rightTopFront),
            (.leftRearSurround, .leftTopRear), (.rightRearSurround, .rightTopRear)
        ]
        for (index, pair) in pairs.enumerated() {
            let source = buses.channels[pair.0.index]
            let target = buses.channels[pair.1.index]
            for frame in 0..<frames {
                target[frame] += state.heightFilters[index].process(source[frame]) * settings.heightAmount
            }
        }
    }

    private func scaleCenter(frames: Int) {
        guard settings.dialogueBoostDB != 0 else {
            return
        }
        let gain = pow(10, settings.dialogueBoostDB / 20)
        let center = buses.channels[CinemaBus.center.index]
        for frame in 0..<frames {
            center[frame] *= gain
        }
    }

    // MARK: - 音量の幅とスピーカーへの送り

    private func applyDynamics(frames: Int) {
        guard settings.dynamicRange != .cinema else {
            return
        }
        let channels = buses.channels
        for frame in 0..<frames {
            var power = sub.channels[0][frame] * sub.channels[0][frame]
            for bus in 0..<channels.count {
                power += channels[bus][frame] * channels[bus][frame]
            }
            let gain = state.dynamics.gain(power: power, mode: settings.dynamicRange)
            for bus in 0..<channels.count {
                channels[bus][frame] *= gain
            }
            sub.channels[0][frame] *= gain
            sub.channels[1][frame] *= gain
        }
    }

    private func writeFeeds(output: [UnsafeMutablePointer<Float>], frames: Int) {
        for (index, feed) in feeds.enumerated() where index < output.count {
            let target = output[index]
            let gain = feed.gain
            if feed.bus == .lfe {
                for frame in 0..<frames {
                    target[frame] = state.feedDelays[index].process((sub.channels[0][frame] + sub.channels[1][frame]) * gain)
                }
            } else {
                let source = buses.channels[feed.bus.index]
                for frame in 0..<frames {
                    target[frame] = state.feedDelays[index].process(source[frame] * gain)
                }
            }
        }
    }
}

/// チャンネルごとの float の領域（処理のあいだ使い回す）
final class PlanarBuffer {
    let channels: [UnsafeMutablePointer<Float>]
    let frames: Int

    init(channels count: Int, frames: Int) {
        self.frames = frames
        channels = (0..<count).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(repeating: 0, count: frames)
            return pointer
        }
    }

    func clear(frames count: Int) {
        for channel in channels {
            channel.update(repeating: 0, count: min(count, frames))
        }
    }

    deinit {
        for channel in channels {
            channel.deallocate()
        }
    }
}
