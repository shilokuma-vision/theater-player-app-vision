//
//  ProcessorState.swift
//  CinemaAudio
//
//  CinemaProcessor の途中の状態（フィルター・遅延・アップミックス）。設定が変わったら作り直す。
//

import Foundation

struct ProcessorState {
    let upmixer: StereoUpmixer
    /// ステレオを広げないとき、広げるときと同じだけ遅らせる（系統ごと）
    var alignment: [DelayLine]
    /// 広げたサラウンドの遅延（12 ms）と高域の減衰（7 kHz）
    var surroundDelays: [DelayLine]
    var surroundFilters: [Biquad]
    /// 天井へ回す音の低域を落とす
    var heightFilters: [Biquad]
    var bass: BassManager
    var shelf: Biquad
    var reverb: LowFrequencyReverb
    var virtualBass: VirtualBass
    var dynamics: DynamicRangeController
    var limiter: LookaheadLimiter
    var feedDelays: [DelayLine]
    /// アップミックスのサラウンドの受け取り
    let scratch: PlanarBuffer

    init(settings: CinemaAudioSettings, feeds: [SpeakerFeed], sampleRate: Float) throws {
        upmixer = try StereoUpmixer(sampleRate: sampleRate)
        alignment = CinemaBus.allCases.map { _ in DelayLine(frames: StereoUpmixer.latency) }
        surroundDelays = [DelayLine(frames: Int(0.012 * sampleRate)), DelayLine(frames: Int(0.012 * sampleRate))]
        surroundFilters = [
            Biquad.lowPass(frequency: 7_000, sampleRate: sampleRate),
            Biquad.lowPass(frequency: 7_000, sampleRate: sampleRate)
        ]
        heightFilters = (0..<4).map { _ in Biquad.highPass(frequency: 250, sampleRate: sampleRate) }
        bass = BassManager(frequency: settings.crossoverHz, sampleRate: sampleRate)
        shelf = Biquad.lowShelf(frequency: 60, gainDB: settings.bassBoostDB, sampleRate: sampleRate)
        reverb = LowFrequencyReverb(sampleRate: sampleRate, decaySeconds: Self.decay(settings.rumble))
        virtualBass = VirtualBass(sampleRate: sampleRate)
        dynamics = DynamicRangeController(sampleRate: sampleRate)
        limiter = LookaheadLimiter(channels: feeds.count, sampleRate: sampleRate)
        feedDelays = feeds.map { DelayLine(frames: $0.delayFrames) }
        scratch = PlanarBuffer(channels: 2, frames: 4096 * 2)
    }

    /// 低音の残響の長さ（秒）
    static func decay(_ rumble: Float) -> Float {
        0.6 + 1.6 * rumble
    }

    /// 設定の変化に合わせて、フィルターを作り直す
    mutating func apply(_ settings: CinemaAudioSettings, previous: CinemaAudioSettings, sampleRate: Float) {
        if settings.crossoverHz != previous.crossoverHz {
            bass = BassManager(frequency: settings.crossoverHz, sampleRate: sampleRate)
        }
        if settings.bassBoostDB != previous.bassBoostDB {
            shelf = Biquad.lowShelf(frequency: 60, gainDB: settings.bassBoostDB, sampleRate: sampleRate)
        }
        if settings.rumble != previous.rumble {
            reverb = LowFrequencyReverb(sampleRate: sampleRate, decaySeconds: Self.decay(settings.rumble))
        }
        if settings.upmix != previous.upmix {
            upmixer.reset()
        }
    }

    /// サブウーファーの信号に、低音の量・残響をかけ、体感の低音の倍音を harmonics に書く
    mutating func lowFrequency(
        sub: UnsafeMutablePointer<Float>,
        harmonics: UnsafeMutablePointer<Float>,
        frames: Int,
        settings: CinemaAudioSettings
    ) {
        let rumble = settings.rumble * 0.6
        let virtual = settings.virtualBass * 0.8
        for frame in 0..<frames {
            let boosted = shelf.process(sub[frame])
            let wet = rumble > 0 ? reverb.process(boosted) * rumble : 0
            harmonics[frame] = virtual > 0 ? virtualBass.process(boosted) * virtual : 0
            sub[frame] = boosted + wet
        }
    }

    mutating func reset() {
        upmixer.reset()
        for index in alignment.indices {
            alignment[index].reset()
        }
        for index in surroundDelays.indices {
            surroundDelays[index].reset()
            surroundFilters[index].reset()
        }
        for index in heightFilters.indices {
            heightFilters[index].reset()
        }
        for index in feedDelays.indices {
            feedDelays[index].reset()
        }
        bass.reset()
        shelf.reset()
        dynamics.reset()
        limiter.reset()
    }
}
