//
//  Sound.swift
//  ReviewSample
//
//  サンプルの動画の音（48 kHz・5.1）。すべてコードで作る（試験の音・ピンクノイズ・和音とベルの音楽）。
//

import Foundation

/// ピンクノイズ（Paul Kellet の方法）。種を決めた乱数で、何度作っても同じ音になる
struct PinkNoise {
    private var state: UInt64
    private var filter = [Double](repeating: 0, count: 7)

    init(seed: UInt64) {
        state = seed
    }

    /// -1〜1 の白色雑音（SplitMix64）
    private mutating func white() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / Double(1 << 53) * 2 - 1
    }

    mutating func next() -> Double {
        let input = white()
        filter[0] = 0.99886 * filter[0] + input * 0.0555179
        filter[1] = 0.99332 * filter[1] + input * 0.0750759
        filter[2] = 0.96900 * filter[2] + input * 0.1538520
        filter[3] = 0.86650 * filter[3] + input * 0.3104856
        filter[4] = 0.55000 * filter[4] + input * 0.5329522
        filter[5] = -0.7616 * filter[5] - input * 0.0168980
        let sum = filter[0...5].reduce(0, +) + filter[6] + input * 0.5362
        filter[6] = input * 0.115926
        return sum * 0.11
    }
}

struct Sound {
    static let sampleRate: Double = 48_000

    private var noise = PinkNoise(seed: 0x5EED_0001)

    /// その時刻の 1 サンプル（6 チャンネル。Speaker の rawValue の順）
    mutating func frame(at time: Double) -> [Double] {
        var channels = [Double](repeating: 0, count: Speaker.allCases.count)
        let (part, local) = Part.at(time)
        switch part {
        case .title:
            let chord = Self.pad(chord: 0, time: time) * Self.fade(local, length: part.length, edge: 2) * 0.6
            add(chord, to: &channels, front: 1, surround: 0.5)
        case .countdown:
            channels[Speaker.center.rawValue] = Self.countdownBeep(local)
        case .bars:
            let tone = sin(2 * .pi * 1_000 * time) * 0.1 * Self.fade(local, length: part.length, edge: 0.02)
            channels[Speaker.left.rawValue] = tone
            channels[Speaker.right.rawValue] = tone
        case .speakers:
            speakerCheck(local, into: &channels)
        case .around:
            let level = noise.next() * Self.fade(local, length: part.length, edge: 0.5) * 0.9
            for (speaker, gain) in Speaker.panGains(angle: Speaker.aroundAngle(at: local)) {
                channels[speaker.rawValue] = level * gain
            }
        case .music, .credits:
            music(time: time, into: &channels)
        }
        return channels.map(Self.softClip)
    }

    // MARK: - 試験の音

    /// 開演前のカウントダウン：1 秒ごとに 1 kHz を 0.12 秒鳴らす
    private static func countdownBeep(_ local: Double) -> Double {
        let within = local.truncatingRemainder(dividingBy: 1)
        guard within < 0.12 else {
            return 0
        }
        return sin(2 * .pi * 1_000 * within) * 0.25 * fade(within, length: 0.12, edge: 0.005)
    }

    /// スピーカーを 1 台ずつ鳴らす：前の 5 台はピンクノイズ、サブウーファーは 50 Hz
    private mutating func speakerCheck(_ local: Double, into channels: inout [Double]) {
        let (speaker, isOn) = Speaker.check(at: local)
        let noiseValue = noise.next()
        guard isOn else {
            return
        }
        let within = local.truncatingRemainder(dividingBy: 1)
        let envelope = Self.fade(within, length: 0.75, edge: 0.01)
        if speaker == .lfe {
            channels[speaker.rawValue] = sin(2 * .pi * 50 * local) * 0.35 * envelope
        } else {
            channels[speaker.rawValue] = noiseValue * envelope
        }
    }

    // MARK: - 音楽

    /// 和音の進行（D・Bm・G・A。MIDI の音の番号）。1 つの和音を 8 秒鳴らす
    static let chords: [[Double]] = [[50, 57, 62, 66], [47, 54, 59, 62], [43, 50, 55, 59], [45, 52, 57, 61]]
    /// サブウーファーで鳴らす根音（MIDI の音の番号）
    static let roots: [Double] = [38, 35, 31, 33]
    static let chordLength: Double = 8
    /// ベルを鳴らす間隔（秒）
    static let bellInterval: Double = 1.25

    static func frequency(_ note: Double) -> Double {
        440 * pow(2, (note - 69) / 12)
    }

    /// 和音のパッド（少しずらした 2 つの正弦波と、倍音）
    static func pad(chord index: Int, time: Double) -> Double {
        chords[index % chords.count].reduce(0) { sum, note in
            let base = frequency(note)
            let voice = sin(2 * .pi * base * 0.9975 * time) + sin(2 * .pi * base * 1.0025 * time) + 0.3 * sin(2 * .pi * base * 2 * time)
            return sum + voice * 0.035
        }
    }

    /// 音楽（パッドとベル）。和音は 3 秒かけて入れ替える
    private func music(time: Double, into channels: inout [Double]) {
        let start = Part.music.start
        let elapsed = time - start
        let length = Part.music.length + Part.credits.length
        let overall = Self.fade(elapsed, length: length, edge: 6) * min(1, (length - elapsed) / 14)
        let step = elapsed / Self.chordLength
        let index = Int(step)
        let blend = min(1, max(0, (step - Double(index) - 0.8) / 0.2))
        let pad = Self.pad(chord: index, time: time) * (1 - blend) + Self.pad(chord: index + 1, time: time) * blend
        let root = Self.root(index, time: time) * (1 - blend) + Self.root(index + 1, time: time) * blend
        add(pad * overall, to: &channels, front: 1, surround: 0.7)
        channels[Speaker.lfe.rawValue] += root * overall
        addBells(elapsed: elapsed, gain: overall, into: &channels)
    }

    /// サブウーファーの根音
    static func root(_ index: Int, time: Double) -> Double {
        sin(2 * .pi * frequency(roots[index % roots.count]) * time) * 0.3
    }

    /// ベル（和音の高い音を、映画館のあちこちのスピーカーから鳴らす）
    private func addBells(elapsed: Double, gain: Double, into channels: inout [Double]) {
        let latest = Int(elapsed / Self.bellInterval)
        for bell in max(0, latest - 4)...latest {
            let age = elapsed - Double(bell) * Self.bellInterval
            guard age >= 0 else {
                continue
            }
            let hash = (bell &* 2_654_435_761) & 0xFFFF
            let chord = Self.chords[Int(Double(bell) * Self.bellInterval / Self.chordLength) % Self.chords.count]
            let note = chord[hash % chord.count] + (hash.isMultiple(of: 3) ? 24 : 12)
            let speakers: [Speaker] = [.left, .center, .right, .rightSurround, .leftSurround]
            let speaker = speakers[(hash / 7) % speakers.count]
            let attack = min(1, age / 0.004)
            let tone = sin(2 * .pi * Self.frequency(note) * age) + 0.25 * sin(2 * .pi * Self.frequency(note) * 2.76 * age)
            channels[speaker.rawValue] += tone * attack * exp(-age / 1.1) * 0.12 * gain
        }
    }

    // MARK: - 共通

    private func add(_ value: Double, to channels: inout [Double], front: Double, surround: Double) {
        channels[Speaker.left.rawValue] += value * front
        channels[Speaker.right.rawValue] += value * front
        channels[Speaker.center.rawValue] += value * front * 0.5
        channels[Speaker.leftSurround.rawValue] += value * surround
        channels[Speaker.rightSurround.rawValue] += value * surround
    }

    /// 始まりと終わりを edge 秒かけて上げ下げする（0〜1）
    static func fade(_ local: Double, length: Double, edge: Double) -> Double {
        max(0, min(1, local / edge, (length - local) / edge))
    }

    /// 音割れを防ぐ（0.9 を超えたところだけ、なめらかに抑える）
    static func softClip(_ value: Double) -> Double {
        guard abs(value) > 0.9 else {
            return value
        }
        let sign: Double = value < 0 ? -1 : 1
        return sign * (0.9 + 0.1 * tanh((abs(value) - 0.9) / 0.1))
    }
}
