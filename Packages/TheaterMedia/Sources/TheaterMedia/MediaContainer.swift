//
//  MediaContainer.swift
//  TheaterMedia
//
//  ファイルの入れ物（AVFormatContext）。開く・パケットを読む・シークする・情報を集める。
//

import CFFmpeg
import CoreGraphics
import Foundation
import ImageIO

/// FFmpeg のエラーの文字列
func ffmpegErrorString(_ code: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    tp_error_string(code, &buffer, buffer.count)
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(bytes: bytes, encoding: .utf8) ?? ""
}

/// 0 未満なら MediaError を投げる。what（できなかったこと）の訳のあとに、FFmpeg のエラーの説明（英語）を付ける
@discardableResult
func check(_ code: Int32, _ what: String.LocalizationValue) throws -> Int32 {
    if code < 0 {
        let failure = String(localized: what, bundle: .module)
        throw MediaError(localized: "\(failure): \(ffmpegErrorString(code))")
    }
    return code
}

final class MediaContainer: @unchecked Sendable {
    let context: UnsafeMutablePointer<AVFormatContext>
    private let interrupt: OpaquePointer

    init(url: URL) throws {
        tp_quiet_logs()
        guard let interrupt = tp_interrupt_create() else {
            throw MediaError(localized: "Can’t open the file.")
        }
        self.interrupt = interrupt
        var pointer = avformat_alloc_context()
        guard let allocated = pointer else {
            tp_interrupt_destroy(interrupt)
            throw MediaError(localized: "Can’t open the file.")
        }
        tp_set_interrupt(allocated, interrupt)
        var options: OpaquePointer?
        // 大きな MKV・TS でも、トラックをすべて見つけられるよう少し長く調べる
        av_dict_set(&options, "probesize", "20000000", 0)
        av_dict_set(&options, "analyzeduration", "10000000", 0)
        let opened = avformat_open_input(&pointer, url.path, nil, &options)
        av_dict_free(&options)
        guard opened >= 0, let context = pointer else {
            tp_interrupt_destroy(interrupt)
            throw MediaError(localized: "Can’t open the file: \(ffmpegErrorString(opened))")
        }
        self.context = context
        do {
            try check(avformat_find_stream_info(context, nil), "Can’t read the file format")
        } catch {
            var closing: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&closing)
            tp_interrupt_destroy(interrupt)
            throw error
        }
    }

    deinit {
        var closing: UnsafeMutablePointer<AVFormatContext>? = context
        avformat_close_input(&closing)
        tp_interrupt_destroy(interrupt)
    }

    /// 読み込みを中断させる（別のスレッドから呼んでよい）
    func requestInterrupt() {
        tp_interrupt_request(interrupt)
    }

    var streamCount: Int {
        Int(context.pointee.nb_streams)
    }

    func stream(_ index: Int) -> UnsafeMutablePointer<AVStream>? {
        guard index >= 0, index < streamCount else {
            return nil
        }
        return context.pointee.streams[index]
    }

    /// 次のパケットを読む。終わりなら nil。packet は呼び出し側が持つ
    func read(into packet: UnsafeMutablePointer<AVPacket>) throws -> Bool {
        let result = av_read_frame(context, packet)
        if result == tp_error_eof() {
            return false
        }
        try check(result, "Can’t read the file")
        return true
    }

    /// 読み込みがファイルの終わりに着いた、または読めなくなった（av_read_frame の失敗を終わりとみなす）
    var isAtEnd: Bool {
        guard let io = context.pointee.pb else {
            return false
        }
        return avio_feof(io) != 0 || io.pointee.error != 0
    }

    /// seconds の手前のキーフレームへ移る
    func seek(to seconds: Double) throws {
        let target = Int64(max(0, seconds) * Double(tp_time_base()))
        try check(avformat_seek_file(context, -1, Int64.min, target, target, 0), "Can’t seek")
    }

    // MARK: - 情報

    /// 長さ（秒）
    var duration: Double? {
        context.pointee.duration > 0 ? Double(context.pointee.duration) / Double(tp_time_base()) : nil
    }

    func metadata(_ key: String) -> String? {
        Self.value(context.pointee.metadata, key)
    }

    static func value(_ dictionary: OpaquePointer?, _ key: String) -> String? {
        guard let entry = av_dict_get(dictionary, key, nil, 0), let value = entry.pointee.value else {
            return nil
        }
        let text = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var formatName: String {
        context.pointee.iformat.map { String(cString: $0.pointee.name) } ?? "?"
    }

    var chapters: [Chapter] {
        (0..<Int(context.pointee.nb_chapters)).compactMap { index in
            guard let chapter = context.pointee.chapters[index] else {
                return nil
            }
            let base = av_q2d(chapter.pointee.time_base)
            return Chapter(
                id: index,
                start: Double(chapter.pointee.start) * base,
                end: Double(chapter.pointee.end) * base,
                title: Self.value(chapter.pointee.metadata, "title")
            )
        }
    }

    /// 埋め込みのジャケット（attached_pic）。JPEG・PNG を ImageIO で読む
    var artwork: CGImage? {
        for index in 0..<streamCount {
            guard let stream = stream(index), stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 else {
                continue
            }
            let packet = stream.pointee.attached_pic
            guard let bytes = packet.data, packet.size > 0 else {
                continue
            }
            let data = Data(bytes: bytes, count: Int(packet.size)) as CFData
            if let source = CGImageSourceCreateWithData(data, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return image
            }
        }
        return nil
    }
}
