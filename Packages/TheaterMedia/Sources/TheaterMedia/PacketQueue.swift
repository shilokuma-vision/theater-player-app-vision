//
//  PacketQueue.swift
//  TheaterMedia
//
//  読んだパケットを、デコードのスレッドへ渡す待ち行列。シークのたびに番号（serial）を進め、古い番号のパケットは捨てる。
//

import CFFmpeg
import Foundation

/// 待ち行列の 1 つ
enum QueuedPacket {
    /// パケット（受け取った側が av_packet_free する）
    case packet(UnsafeMutablePointer<AVPacket>, serial: Int)
    /// ファイルの終わり（デコーダーに残りを出させる）
    case endOfStream(serial: Int)
}

final class PacketQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var items: [QueuedPacket] = []
    private var bytes = 0
    private var aborted = false
    /// 待ち行列が抱えるデータの目安（これを超えたら読み込みを待たせる）
    let maxBytes: Int
    let maxPackets: Int

    init(maxBytes: Int = 24 << 20, maxPackets: Int = 600) {
        self.maxBytes = maxBytes
        self.maxPackets = maxPackets
    }

    deinit {
        Self.free(items)
    }

    var isFull: Bool {
        condition.lock()
        defer { condition.unlock() }
        return bytes >= maxBytes || items.count >= maxPackets
    }

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return items.count
    }

    var isEmpty: Bool {
        condition.lock()
        defer { condition.unlock() }
        return items.isEmpty
    }

    /// パケットの複製を入れる（packet は呼び出し側がそのまま使い続けてよい）
    func put(copyOf packet: UnsafeMutablePointer<AVPacket>, serial: Int) {
        guard let copy = av_packet_alloc() else {
            return
        }
        av_packet_move_ref(copy, packet)
        condition.lock()
        // 閉じた後は受け取らない（取り出す側がもういない）
        guard !aborted else {
            condition.unlock()
            Self.free([.packet(copy, serial: serial)])
            return
        }
        items.append(.packet(copy, serial: serial))
        bytes += Int(copy.pointee.size)
        condition.signal()
        condition.unlock()
    }

    func putEndOfStream(serial: Int) {
        condition.lock()
        items.append(.endOfStream(serial: serial))
        condition.signal()
        condition.unlock()
    }

    /// 取り出す。空なら入るまで待つ（timeout 秒で nil）。中断されたら nil
    func take(timeout: TimeInterval = 0.1) -> QueuedPacket? {
        condition.lock()
        defer { condition.unlock() }
        if items.isEmpty && !aborted {
            condition.wait(until: Date().addingTimeInterval(timeout))
        }
        guard !aborted, !items.isEmpty else {
            return nil
        }
        let item = items.removeFirst()
        if case let .packet(packet, _) = item {
            bytes -= Int(packet.pointee.size)
        }
        return item
    }

    /// 中身を捨てる（シークのとき）
    func flush() {
        condition.lock()
        let old = items
        items.removeAll()
        bytes = 0
        condition.broadcast()
        condition.unlock()
        Self.free(old)
    }

    /// 待っているスレッドを起こし、以後は何も返さない（閉じるとき）
    func abort() {
        condition.lock()
        aborted = true
        let old = items
        items.removeAll()
        bytes = 0
        condition.broadcast()
        condition.unlock()
        Self.free(old)
    }

    private static func free(_ items: [QueuedPacket]) {
        for item in items {
            if case let .packet(packet, _) = item {
                var pointer: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&pointer)
            }
        }
    }
}
