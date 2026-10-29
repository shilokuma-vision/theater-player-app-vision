//
//  main.swift
//  stereo-convert
//
//  2D の動画を、深度推定で左右に並べた 3D の動画に変換する。使い方は Options.usage と README.md
//

import Foundation

do {
    let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
    try await Converter(options: options).run()
} catch let error as ConvertError {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("エラー：\(error.localizedDescription)\n".utf8))
    exit(1)
}
