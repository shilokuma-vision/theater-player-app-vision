//
//  Chapters.swift
//  ReviewSample
//
//  チャプター（Nero 形式。moov/udta/chpl）を、書き出した QuickTime のファイルに書き足す。
//  アプリは FFmpeg（libavformat/mov.c の mov_read_chpl）でチャプターを読む。
//  AVAssetWriter のチャプターのトラック（テキスト）は、macOS 26 で書き終えるときに「format description is invalid」で失敗したので使わない。
//

import Foundation

enum Chapters {
    enum Failure: Error {
        case noMovieAtEnd
    }

    /// chpl の中身（FFmpeg の mov の書き出しと同じ形：版 1・予約 4 バイト・数・各チャプターの始まり（100 ns 単位）と名前）
    static func chapterList() -> Data {
        var body = Data([1, 0, 0, 0, 0, 0, 0, 0, UInt8(Part.allCases.count)])
        for part in Part.allCases {
            body.append(bigEndian: UInt64(part.start * 10_000_000))
            let title = Data(part.name.utf8.prefix(255))
            body.append(UInt8(title.count))
            body.append(title)
        }
        return atom("chpl", body)
    }

    /// moov（ファイルの最後にある）の udta に chpl を足す。moov の後ろに何も無いので、ほかの位置（チャンクの位置）は変わらない
    static func write(to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var offset: UInt64 = 0
        var movieOffset: UInt64?
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            let header = try handle.read(upToCount: 8) ?? Data()
            let size = UInt64(header.bigEndianUInt32(at: 0))
            guard size >= 8 else {
                break
            }
            if header[4..<8] == Data("moov".utf8) {
                movieOffset = offset
            }
            offset += size
        }
        guard let movieOffset, offset == fileSize else {
            throw Failure.noMovieAtEnd
        }
        try handle.seek(toOffset: movieOffset)
        var movie = try handle.readToEnd() ?? Data()
        if let userData = childOffset(of: "udta", in: movie) {
            let size = Int(movie.bigEndianUInt32(at: userData))
            movie.insert(contentsOf: chapterList(), at: userData + size)
            movie.replaceBigEndianUInt32(at: userData, with: UInt32(size + chapterList().count))
        } else {
            movie.append(atom("udta", chapterList()))
        }
        movie.replaceBigEndianUInt32(at: 0, with: UInt32(movie.count))
        try handle.seek(toOffset: movieOffset)
        try handle.write(contentsOf: movie)
    }

    /// moov の直下にある子の位置
    private static func childOffset(of type: String, in movie: Data) -> Int? {
        var position = 8
        while position + 8 <= movie.count {
            let size = Int(movie.bigEndianUInt32(at: position))
            guard size >= 8 else {
                return nil
            }
            if movie[(position + 4)..<(position + 8)] == Data(type.utf8) {
                return position
            }
            position += size
        }
        return nil
    }

    private static func atom(_ type: String, _ body: Data) -> Data {
        var data = Data()
        data.append(bigEndian: UInt32(8 + body.count))
        data.append(Data(type.utf8))
        data.append(body)
        return data
    }
}

extension Data {
    mutating func append(bigEndian value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func bigEndianUInt32(at offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func replaceBigEndianUInt32(at offset: Int, with value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { replaceSubrange(offset..<(offset + 4), with: $0) }
    }
}
