//
//  MediaTracks.swift
//  TheaterMedia
//
//  ストリームから、映像・音声・字幕のトラックの一覧を作る。
//

import CFFmpeg
import Foundation

enum MediaTracks {
    static func codecName(_ parameters: AVCodecParameters) -> String {
        avcodec_get_name(parameters.codec_id).map { String(cString: $0) } ?? "?"
    }

    /// 映像に付いた回転（時計回りの度。0・90・180・270）
    static func rotation(of stream: UnsafeMutablePointer<AVStream>) -> Int {
        let parameters = stream.pointee.codecpar.pointee
        guard let side = av_packet_side_data_get(parameters.coded_side_data, parameters.nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX),
              let data = side.pointee.data, side.pointee.size >= 36 else {
            return 0
        }
        let angle = data.withMemoryRebound(to: Int32.self, capacity: 9) { av_display_rotation_get($0) }
        guard angle.isFinite else {
            return 0
        }
        let clockwise = Int((-angle / 90).rounded()) * 90
        return ((clockwise % 360) + 360) % 360
    }

    static func language(_ stream: UnsafeMutablePointer<AVStream>) -> String? {
        MediaContainer.value(stream.pointee.metadata, "language").flatMap { $0 == "und" ? nil : $0 }
    }

    static func title(_ stream: UnsafeMutablePointer<AVStream>) -> String? {
        MediaContainer.value(stream.pointee.metadata, "title")
    }

    static func video(_ container: MediaContainer) -> [VideoTrack] {
        (0..<container.streamCount).compactMap { index in
            guard let stream = container.stream(index) else {
                return nil
            }
            let parameters = stream.pointee.codecpar.pointee
            guard parameters.codec_type == AVMEDIA_TYPE_VIDEO, stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0 else {
                return nil
            }
            let aspect = parameters.sample_aspect_ratio
            let pixelAspect = aspect.num > 0 && aspect.den > 0 ? av_q2d(aspect) : 1
            let rate = av_q2d(stream.pointee.avg_frame_rate)
            return VideoTrack(
                id: index,
                codec: codecName(parameters),
                width: Int(parameters.width),
                height: Int(parameters.height),
                displayAspect: Double(parameters.width) * pixelAspect / Double(max(parameters.height, 1)),
                frameRate: rate > 0 ? rate : nil,
                rotation: rotation(of: stream),
                isHDR: parameters.color_trc == AVCOL_TRC_SMPTE2084 || parameters.color_trc == AVCOL_TRC_ARIB_STD_B67,
                isInterlaced: parameters.field_order != AV_FIELD_UNKNOWN && parameters.field_order != AV_FIELD_PROGRESSIVE
            )
        }
    }

    static func audio(_ container: MediaContainer) -> [AudioTrack] {
        (0..<container.streamCount).compactMap { index in
            guard let stream = container.stream(index) else {
                return nil
            }
            var parameters = stream.pointee.codecpar.pointee
            guard parameters.codec_type == AVMEDIA_TYPE_AUDIO else {
                return nil
            }
            var name = [CChar](repeating: 0, count: 64)
            av_channel_layout_describe(&parameters.ch_layout, &name, name.count)
            let layout = String(bytes: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
            return AudioTrack(
                id: index,
                codec: codecName(parameters),
                channels: Int(parameters.ch_layout.nb_channels),
                layoutName: layout,
                sampleRate: Int(parameters.sample_rate),
                language: language(stream),
                title: title(stream),
                isDefault: stream.pointee.disposition & AV_DISPOSITION_DEFAULT != 0
            )
        }
    }

    static func subtitles(_ container: MediaContainer) -> [SubtitleTrack] {
        (0..<container.streamCount).compactMap { index in
            guard let stream = container.stream(index) else {
                return nil
            }
            let parameters = stream.pointee.codecpar.pointee
            guard parameters.codec_type == AVMEDIA_TYPE_SUBTITLE else {
                return nil
            }
            let properties = avcodec_descriptor_get(parameters.codec_id)?.pointee.props ?? 0
            return SubtitleTrack(
                id: index,
                codec: codecName(parameters),
                language: language(stream),
                title: title(stream),
                isBitmap: properties & AV_CODEC_PROP_BITMAP_SUB != 0,
                isDefault: stream.pointee.disposition & AV_DISPOSITION_DEFAULT != 0,
                isForced: stream.pointee.disposition & AV_DISPOSITION_FORCED != 0,
                isExternal: false
            )
        }
    }
}
