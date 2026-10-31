//
//  Subtitles.swift
//  TheaterMedia
//
//  字幕：文字の字幕（SRT・ASS/SSA・WebVTT・mov_text など）と、画像の字幕（PGS・DVD・DVB）。
//  ファイルに入った字幕と、別のファイル（.srt・.ass・.vtt）の字幕のどちらも、時刻つきの一覧（SubtitleStore）にする。
//

import CFFmpeg
import CoreGraphics
import Foundation

/// 字幕の 1 つ
public struct SubtitleCue: Sendable, Identifiable {
    public let id: Int
    public let start: Double
    public var end: Double
    /// 文字の字幕（改行を含む）
    public let text: String?
    /// 画像の字幕
    public let image: CGImage?
    /// 画像の位置（映像の上の割合。左上が 0）
    public let imageRect: CGRect?
}

/// 時刻つきの字幕の一覧
final class SubtitleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cues: [SubtitleCue] = []
    private var nextID = 0

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cues.removeAll()
    }

    func replace(with newCues: [SubtitleCue]) {
        lock.lock()
        defer { lock.unlock() }
        cues = newCues.sorted { $0.start < $1.start }
    }

    func add(start: Double, end: Double?, text: String?, image: CGImage?, imageRect: CGRect?) {
        lock.lock()
        defer { lock.unlock() }
        // 終わりの分からない字幕（PGS など）は、次の字幕が始まるときに終える
        for index in cues.indices where cues[index].end == .infinity && cues[index].start < start {
            cues[index].end = start
        }
        nextID += 1
        cues.append(SubtitleCue(id: nextID, start: start, end: end ?? .infinity, text: text, image: image, imageRect: imageRect))
        if cues.count > 2_000 {
            cues.removeFirst(cues.count - 2_000)
        }
    }

    /// 終わりの分からない字幕を time で終える（画像の字幕の「消す」）
    func endOpenCues(at time: Double) {
        lock.lock()
        defer { lock.unlock() }
        for index in cues.indices where cues[index].end == .infinity && cues[index].start <= time {
            cues[index].end = time
        }
    }

    func cues(at time: Double) -> [SubtitleCue] {
        lock.lock()
        defer { lock.unlock() }
        return cues.filter { $0.start <= time && time < $0.end }
    }

    /// すべての字幕（始まりの順）
    func allCues() -> [SubtitleCue] {
        lock.lock()
        defer { lock.unlock() }
        return cues.sorted { $0.start < $1.start }
    }
}

/// 字幕のデコード
final class SubtitleDecoder: @unchecked Sendable {
    let streamIndex: Int
    private let codec: UnsafeMutablePointer<AVCodecContext>
    private let timeBase: AVRational
    private let startTime: Double
    private let store: SubtitleStore
    /// 画像の字幕の画面の大きさ（分からなければ映像の大きさ）
    var canvas = CGSize(width: 1_920, height: 1_080)

    init(
        stream: UnsafeMutablePointer<AVStream>,
        index: Int,
        startTime: Double,
        store: SubtitleStore,
        characterEncoding: String? = nil
    ) throws {
        guard let decoder = avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id),
              let context = avcodec_alloc_context3(decoder) else {
            throw MediaError(localized: "This subtitle format isn’t supported.")
        }
        // 先にすべての値を決める（この後で失敗しても deinit が context を解放する）
        codec = context
        streamIndex = index
        timeBase = stream.pointee.time_base
        self.startTime = startTime
        self.store = store
        try check(avcodec_parameters_to_context(context, stream.pointee.codecpar), "Can’t set up the subtitles")
        context.pointee.pkt_timebase = stream.pointee.time_base
        var options: OpaquePointer?
        if let characterEncoding {
            av_dict_set(&options, "sub_charenc", characterEncoding, 0)
        }
        let opened = avcodec_open2(context, decoder, &options)
        av_dict_free(&options)
        try check(opened, "Can’t open the subtitle decoder")
        if context.pointee.width > 0, context.pointee.height > 0 {
            canvas = CGSize(width: Int(context.pointee.width), height: Int(context.pointee.height))
        }
    }

    deinit {
        var context: UnsafeMutablePointer<AVCodecContext>? = codec
        avcodec_free_context(&context)
    }

    /// 今の画像の字幕の画面の大きさ。PGS・DVB はパケットごとにデコーダーの大きさを決め直すので、デコードのたびに読む
    private var currentCanvas: CGSize {
        let width = codec.pointee.width
        let height = codec.pointee.height
        return width > 0 && height > 0 ? CGSize(width: Int(width), height: Int(height)) : canvas
    }

    func decode(_ packet: UnsafeMutablePointer<AVPacket>) {
        var subtitle = AVSubtitle()
        var got: Int32 = 0
        guard avcodec_decode_subtitle2(codec, &subtitle, &got, packet) >= 0, got != 0 else {
            return
        }
        defer { avsubtitle_free(&subtitle) }
        let stamp = packet.pointee.pts != tp_no_pts() ? packet.pointee.pts : packet.pointee.dts
        let base = stamp != tp_no_pts() ? Double(stamp) * av_q2d(timeBase) - startTime : 0
        let start = base + Double(subtitle.start_display_time) / 1_000
        let packetEnd = packet.pointee.duration > 0 ? base + Double(packet.pointee.duration) * av_q2d(timeBase) : nil
        let endTime = subtitle.end_display_time > 0 && subtitle.end_display_time != UInt32.max
            ? base + Double(subtitle.end_display_time) / 1_000 : packetEnd
        guard subtitle.num_rects > 0 else {
            store.endOpenCues(at: start)
            return
        }
        for index in 0..<Int(subtitle.num_rects) {
            guard let rect = subtitle.rects[index] else {
                continue
            }
            add(rect, start: start, end: endTime)
        }
    }

    private func add(_ rect: UnsafeMutablePointer<AVSubtitleRect>, start: Double, end: Double?) {
        switch rect.pointee.type {
        case SUBTITLE_ASS:
            if let line = rect.pointee.ass {
                let text = SubtitleText.fromASSEvent(String(cString: line))
                if !text.isEmpty {
                    store.add(start: start, end: end, text: text, image: nil, imageRect: nil)
                }
            }
        case SUBTITLE_TEXT:
            if let line = rect.pointee.text {
                store.add(start: start, end: end, text: SubtitleText.clean(String(cString: line)), image: nil, imageRect: nil)
            }
        case SUBTITLE_BITMAP:
            if let image = SubtitleBitmap.image(rect) {
                let canvas = currentCanvas
                let frame = CGRect(
                    x: CGFloat(rect.pointee.x) / canvas.width,
                    y: CGFloat(rect.pointee.y) / canvas.height,
                    width: CGFloat(rect.pointee.w) / canvas.width,
                    height: CGFloat(rect.pointee.h) / canvas.height
                )
                store.add(start: start, end: end, text: nil, image: image, imageRect: frame)
            }
        default:
            break
        }
    }
}

/// 文字の字幕の整形
enum SubtitleText {
    /// FFmpeg の ASS のイベント（ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text）から本文を取り出す
    static func fromASSEvent(_ event: String) -> String {
        let fields = event.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        let text = fields.count == 9 ? String(fields[8]) : event
        return clean(text)
    }

    /// ASS の上書きのタグ（{\an8} など）・HTML のタグを消し、改行の記号を改行にする
    static func clean(_ text: String) -> String {
        var out = text
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
        out = out.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 画像の字幕（パレットの番号の画素）を CGImage にする
enum SubtitleBitmap {
    static func image(_ rect: UnsafeMutablePointer<AVSubtitleRect>) -> CGImage? {
        let width = Int(rect.pointee.w)
        let height = Int(rect.pointee.h)
        guard width > 0, height > 0, let indices = tp_subtitle_rect_data(rect, 0), let palette = tp_subtitle_rect_data(rect, 1) else {
            return nil
        }
        let stride = Int(tp_subtitle_rect_linesize(rect, 0))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        palette.withMemoryRebound(to: UInt32.self, capacity: 256) { colors in
            for row in 0..<height {
                for column in 0..<width {
                    // パレットは AV_PIX_FMT_RGB32（0xAARRGGBB）
                    let color = colors[Int(indices[row * stride + column])]
                    let alpha = UInt8(color >> 24 & 0xFF)
                    let offset = (row * width + column) * 4
                    pixels[offset] = UInt8(color >> 16 & 0xFF)
                    pixels[offset + 1] = UInt8(color >> 8 & 0xFF)
                    pixels[offset + 2] = UInt8(color & 0xFF)
                    pixels[offset + 3] = alpha
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// 別のファイルの字幕（.srt・.ass・.ssa・.vtt・.sub など。FFmpeg が読める物）
enum ExternalSubtitles {
    static func load(_ url: URL) throws -> [SubtitleCue] {
        let container = try MediaContainer(url: url)
        let streams = (0..<container.streamCount).compactMap { container.stream($0) }
        guard let index = streams.firstIndex(where: { $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE }) else {
            throw MediaError(localized: "No subtitles found.")
        }
        let store = SubtitleStore()
        let decoder = try SubtitleDecoder(
            stream: streams[index],
            index: index,
            startTime: 0,
            store: store,
            characterEncoding: characterEncoding(of: url)
        )
        guard let packet = av_packet_alloc() else {
            throw MediaError(localized: "Can’t read the subtitles.")
        }
        var pointer: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&pointer) }
        while try container.read(into: packet) {
            if Int(packet.pointee.stream_index) == index {
                decoder.decode(packet)
            }
            av_packet_unref(packet)
        }
        return store.allCues()
    }

    /// 文字の符号化。BOM のある UTF-8・UTF-16 は FFmpeg の読み込みが UTF-8 にするので指定しない（指定すると二重に変換する）。
    /// BOM が無く UTF-8 でもない文字は、日本語の Shift_JIS（CP932）とみなして変換する
    static func characterEncoding(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let head = [UInt8](data.prefix(3))
        if head.starts(with: [0xEF, 0xBB, 0xBF]) || head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) {
            return nil
        }
        return String(data: data, encoding: .utf8) == nil ? "CP932" : nil
    }
}
