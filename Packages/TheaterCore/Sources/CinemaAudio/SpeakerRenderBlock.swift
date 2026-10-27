//
//  SpeakerRenderBlock.swift
//  CinemaAudio
//
//  RealityKit の空間オーディオの音源（Entity.prepareAudio(configuration:_:) の生成器）に渡す、描画の関数。
//  オーディオのリアルタイムのスレッドから呼ばれるので、MainActor の外（このパッケージ）で作る
//  （MainActor が既定のアプリの中でクロージャを作ると、別のスレッドから呼ばれたときに実行時の分離の検査で止まる）。
//

import AVFAudio
import Foundation

/// 読み手ごとの、前に掛けた音量（リアルタイムのスレッドだけが触る）
final class RenderGainState: @unchecked Sendable {
    var gain: Float = 0
}

extension SpeakerFeedRing {
    /// feed 番目の信号を鳴らす、モノラルの生成器の描画の関数。sampleRate は描画のサンプルレート
    /// （描画の時刻に mSampleTime が無いとき、ホストの時刻をサンプルの数に直すのに使う）
    public func renderBlock(feed: Int, sampleRate: Double = 48_000) -> AVAudioSourceNodeRenderBlock {
        let state = RenderGainState()
        let samplesPerHostTick = Self.hostTickSeconds * sampleRate
        return { [self] isSilence, timestamp, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let first = buffers.first, let data = first.mData else {
                isSilence.pointee = true
                return noErr
            }
            let frames = Int(frameCount)
            let output = data.assumingMemoryBound(to: Float.self)
            let stamp = timestamp.pointee
            let sampleTime = stamp.mFlags.contains(.sampleTimeValid)
                ? stamp.mSampleTime
                : (Double(stamp.mHostTime) * samplesPerHostTick).rounded()
            read(
                feed: feed,
                into: output,
                frames: frames,
                time: RenderTime(sampleTime: sampleTime, hostTime: stamp.mHostTime),
                previousGain: &state.gain
            )
            // ほかのチャンネル（あれば）にも同じ信号
            for index in 1..<max(buffers.count, 1) {
                if let other = buffers[index].mData {
                    other.copyMemory(from: data, byteCount: frames * MemoryLayout<Float>.size)
                }
            }
            return noErr
        }
    }

    /// ホストの時刻（mach_absolute_time）の 1 単位の秒数
    private static let hostTickSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
}
