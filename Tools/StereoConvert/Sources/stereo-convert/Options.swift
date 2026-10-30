//
//  Options.swift
//  stereo-convert
//
//  コマンドの引数。
//

import AVFoundation
import StereoKit

enum ConvertError: Error, CustomStringConvertible {
    case usage(String)
    case modelMissing(URL)
    case noVideo
    case tooWide(Int, String)
    case failed(String)

    var description: String {
        switch self {
        case let .usage(message):
            message
        case let .modelMissing(url):
            "深度推定のモデルが見つかりません：\(url.path)（入れ方は Tools/StereoConvert/README.md）"
        case .noVideo:
            "映像のトラックがありません"
        case let .tooWide(width, codec):
            "左右に並べると幅が \(width) になり、\(codec) で書けません（--h264 を外して HEVC にしてください）"
        case let .failed(message):
            message
        }
    }
}

struct Options {
    static let usage = """
    使い方: swift run -c release --package-path Tools/StereoConvert stereo-convert <入力の動画> [オプション]
      -o, --output <パス>      出力先（既定：入力と同じフォルダの <名前>_SBS.mp4）
      --strength <割合>        立体の強さ。いちばん近い物と遠い物のずれの差（絵の幅に対する割合。既定 0.03）
      --convergence <0〜1>     画面の面に見える深さ（0 が最も遠い。これより近い物は飛び出す。既定 0.35）
      --seconds <秒>           先頭から指定の秒数だけ変換する（試すとき）
      --h264                   H.264 で書く（既定は HEVC）
      --overwrite              出力先にファイルがあれば上書きする
      --model <パス>           深度推定のモデル（既定：Tools/StereoConvert/Models/DepthAnythingV2SmallF16.mlpackage）
    """

    /// 既定のモデルの置き場（このパッケージの Models フォルダ）
    static let defaultModel = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Models/DepthAnythingV2SmallF16.mlpackage")

    var input: URL
    var output: URL
    var model = defaultModel
    var parameters = StereoParameters()
    var seconds: Double?
    var codec = AVVideoCodecType.hevc
    var overwrite = false

    /// 値を取るオプション
    private static let valued: Set = ["-o", "--output", "--strength", "--convergence", "--seconds", "--model"]

    init(arguments: [String]) throws {
        // 入力の動画（- で始まらない引数）と、オプションを分ける
        var rest = arguments[...]
        var flags: [String] = []
        var input: URL?
        while let argument = rest.popFirst() {
            if argument.hasPrefix("-") {
                flags.append(argument)
                if Self.valued.contains(argument), let value = rest.popFirst() {
                    flags.append(value)
                }
            } else if input == nil {
                input = URL(filePath: argument)
            } else {
                throw ConvertError.usage("入力の動画は 1 つだけ指定してください：\(argument)\n\n\(Self.usage)")
            }
        }
        guard let input else {
            throw ConvertError.usage(Self.usage)
        }
        self.input = input
        output = input.deletingLastPathComponent().appending(path: input.deletingPathExtension().lastPathComponent + "_SBS.mp4")
        var options = flags[...]
        while let flag = options.popFirst() {
            try apply(flag, from: &options)
        }
    }

    private mutating func apply(_ flag: String, from rest: inout ArraySlice<String>) throws {
        switch flag {
        case "-h", "--help":
            throw ConvertError.usage(Self.usage)
        case "-o", "--output":
            output = try URL(filePath: Self.value(of: flag, in: &rest))
        case "--strength":
            parameters.strength = try Self.number(of: flag, in: &rest, range: 0...0.2)
        case "--convergence":
            parameters.convergence = try Self.number(of: flag, in: &rest, range: 0...1)
        case "--seconds":
            seconds = try Double(Self.number(of: flag, in: &rest, range: 0.1...86_400))
        case "--h264":
            codec = .h264
        case "--overwrite":
            overwrite = true
        case "--model":
            model = try URL(filePath: Self.value(of: flag, in: &rest))
        default:
            throw ConvertError.usage("分からない引数：\(flag)\n\n\(Self.usage)")
        }
    }

    private static func value(of name: String, in rest: inout ArraySlice<String>) throws -> String {
        guard let value = rest.popFirst() else {
            throw ConvertError.usage("\(name) の値がありません")
        }
        return value
    }

    private static func number(of name: String, in rest: inout ArraySlice<String>, range: ClosedRange<Float>) throws -> Float {
        let text = try value(of: name, in: &rest)
        guard let number = Float(text), range.contains(number) else {
            throw ConvertError.usage("\(name) は \(range.lowerBound)〜\(range.upperBound) の数で指定してください（\(text)）")
        }
        return number
    }
}
