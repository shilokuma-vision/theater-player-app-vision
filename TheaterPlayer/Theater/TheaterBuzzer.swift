//
//  TheaterBuzzer.swift
//  TheaterPlayer
//
//  開演のブザー。音はコードで合成し（録音した素材を使わない）、場内の天井の中央から鳴らす。
//  映画館の音響（スピーカーの 31 本）とは別の音源で、部屋の響き（ReverbComponent）は同じように効く。
//

@preconcurrency import AVFoundation
import RealityKit
import TheaterScene

/// ブザーの音（電磁式のブザーのような、倍音の多い「ブー」）
enum BuzzerSound {
    static let sampleRate = 48_000.0
    /// 基本の高さ（Hz）。交流で鳴らす電磁式のブザーと同じく、電源の周波数（60 Hz）の 2 倍
    static let pitch = 120.0
    /// 鳴らす長さ（秒）
    static let length = 2.2
    /// 鳴り始め・鳴り終わりの立ち上がりと減衰（秒。ぶつっと切れないように）
    static let attack = 0.02
    static let release = 0.3
    /// 重ねる倍音の上限（Hz）。これより高い倍音は耳に刺さるので入れない
    static let brightness = 3_000.0
    /// 振幅の最大
    static let peak: Float = 0.5
    /// 音量の設定が 1 のときの、音源の強さ（dB）。倍音が多く詰まった音なので（RMS で約 -10 dBFS）、映画の台詞より大きくなりすぎないよう下げる
    static let baseGain = -10.0

    /// 1 チャンネルの音（sampleRate で length 秒）
    static func samples() -> [Float] {
        // 1 周期（48 kHz で 400 サンプル）を倍音で作り、並べる
        let period = Int((sampleRate / pitch).rounded())
        var cycle = [Double](repeating: 0, count: period)
        for harmonic in 1...Int(brightness / pitch) {
            // 高い倍音ほど弱く、偶数の倍音は少し弱く（奇数の倍音が多いと、ブザーらしいざらつきになる）
            let amplitude = (harmonic.isMultiple(of: 2) ? 0.6 : 1) / pow(Double(harmonic), 1.2)
            for index in 0..<period {
                cycle[index] += amplitude * sin(2 * .pi * Double(harmonic * index) / Double(period))
            }
        }
        let largest = cycle.map(abs).max() ?? 1
        let count = Int(length * sampleRate)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let envelope = min(1, time / attack) * min(1, (length - time) / release)
            // 振動板のがたつき：強さがゆっくり揺れる（毎秒 7 回）
            let flutter = 1 - 0.1 * (0.5 + 0.5 * sin(2 * .pi * 7 * time))
            return Float(cycle[index % period] / largest * max(envelope, 0) * flutter) * peak
        }
    }

    /// 音量の設定（0〜1.5）を、音源の強さ（dB）にする。0 なら nil（鳴らさない）
    static func gain(volume: Double) -> Double? {
        guard volume > 0.001 else {
            return nil
        }
        return baseGain + 20 * log10(volume)
    }

    static func makeResource() throws -> AudioBufferResource {
        let samples = samples()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw BufferUnavailable()
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: source.count)
            }
        }
        return try AudioBufferResource(buffer: buffer)
    }

    /// 音を入れる場所を作れなかった
    struct BufferUnavailable: Error {}
}

/// ブザーの音源（天井の中央）
@MainActor
final class TheaterBuzzer {
    private let entity = Entity()
    private var resource: AudioBufferResource?
    private var controller: AudioPlaybackController?

    /// 客席の上の天井の中央に音源を置く（どの席でも同じくらいに聞こえるよう、向きを持たせず、距離で減りにくくする）
    func build(layout: TheaterLayout, parent: Entity) {
        let room = layout.room
        entity.name = "Buzzer"
        entity.position = SIMD3(0, room.max.y - 1.5, (room.min.z + room.max.z) / 2)
        entity.components.set(SpatialAudioComponent(gain: 0, directivity: .beam(focus: 0), distanceAttenuation: .rolloff(factor: 0.3)))
        parent.addChild(entity)
    }

    /// 鳴らす。volume：音量の設定（0〜1.5）
    func play(volume: Double) {
        guard let gain = BuzzerSound.gain(volume: volume) else {
            return
        }
        if resource == nil {
            resource = try? BuzzerSound.makeResource()
        }
        guard let resource else {
            return
        }
        entity.components[SpatialAudioComponent.self]?.gain = gain
        controller?.stop()
        controller = entity.playAudio(resource)
    }

    /// 鳴っていれば止める（開演の流れを省いて、すぐに始めたとき）
    func stop() {
        controller?.stop()
        controller = nil
    }
}
