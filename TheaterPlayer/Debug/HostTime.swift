//
//  HostTime.swift
//  TheaterPlayer
//
//  デバッグ用（デバッグのビルドだけ）：ホストの時刻（mach_absolute_time）を秒に直す（SpeakerRoute・YouTubeSound）。
//

#if DEBUG
import Darwin

/// ホストの時刻（mach_absolute_time）の差
nonisolated enum HostTime {
    /// 1 単位の秒数
    static let tickSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? Double(end - start) * tickSeconds : -Double(start - end) * tickSeconds
    }
}
#endif
