//
//  SpeakerRoute.swift
//  TheaterPlayer
//
//  デバッグ用（デバッグのビルドだけ）：空間オーディオの音源（SpatialSpeakers）が鳴らす輪のバッファを、
//  再生のエンジン（手元のファイル）の物から、YouTube の音（YouTubeSound）の物へ切り替える。
//  音源を作り直さずに切り替えられるよう、描画の関数の中で、どちらを読むかを決める。
//  音源は舞台を作るたびに作り直し、YouTube の音はアプリに 1 つなので、どちらからも届くよう 1 つだけ持つ（shared）。
//

#if DEBUG
import AVFAudio
import CinemaAudio
import Synchronization

nonisolated final class SpeakerRoute: Sendable {
    static let shared = SpeakerRoute()

    /// 再生のエンジンの物の代わりに鳴らす輪のバッファ（nil なら再生のエンジンの物）
    private let replacement = Mutex<SpeakerFeedRing?>(nil)

    func use(_ ring: SpeakerFeedRing?) {
        replacement.withLock { $0 = ring }
    }

    /// feed 番目の音源の描画の関数（SpeakerFeedRing.renderBlock と同じく、オーディオのリアルタイムのスレッドから呼ばれる）。
    /// MainActor の外（nonisolated）で作る（MainActor の中で作ったクロージャは、別のスレッドから呼ぶと実行時の分離の検査で止まる）
    func renderBlock(feed: Int, main: SpeakerFeedRing) -> AVAudioSourceNodeRenderBlock {
        let mainBlock = main.renderBlock(feed: feed)
        let gain = ReplacementGain()
        return { [self] isSilence, timestamp, frameCount, bufferList in
            guard let ring = replacement.withLock({ $0 }) else {
                // 次に切り替えたとき、無音から上げる
                gain.value = 0
                return mainBlock(isSilence, timestamp, frameCount, bufferList)
            }
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let first = buffers.first, let data = first.mData else {
                isSilence.pointee = true
                return noErr
            }
            let frames = Int(frameCount)
            let stamp = timestamp.pointee
            let sampleTime = stamp.mFlags.contains(.sampleTimeValid)
                ? stamp.mSampleTime
                : (Double(stamp.mHostTime) * HostTime.tickSeconds * ring.sampleRate).rounded()
            ring.read(
                feed: feed,
                into: data.assumingMemoryBound(to: Float.self),
                frames: frames,
                time: RenderTime(sampleTime: sampleTime, hostTime: stamp.mHostTime),
                previousGain: &gain.value
            )
            for index in 1..<max(buffers.count, 1) {
                if let other = buffers[index].mData {
                    other.copyMemory(from: data, byteCount: frames * MemoryLayout<Float>.size)
                }
            }
            return noErr
        }
    }
}

/// 読み手ごとの、代わりの輪のバッファに前に掛けた音量（リアルタイムのスレッドだけが触る）
nonisolated private final class ReplacementGain: @unchecked Sendable {
    var value: Float = 0
}
#endif
