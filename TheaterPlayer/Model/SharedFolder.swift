//
//  SharedFolder.swift
//  TheaterPlayer
//
//  「ファイル」App の「この Apple Vision Pro内」に出す、アプリのフォルダ（Documents。Info.plist の UIFileSharingEnabled）。
//  フォルダが空だと「ファイル」App に出ない（visionOS 26.5 の Simulator で確かめた）ので、空なら使い方の案内を 1 つ置く。
//

import Foundation

nonisolated enum SharedFolder {
    /// 案内のファイルの名前
    static var guideName: String {
        String(localized: "How to Use.txt", comment: "File name of the guide placed in the app’s folder in the Files app.")
    }

    static var guideText: String {
        String(localized: """
        To play videos, music, pictures, and PDFs you put in this folder, \
        use “Choose a File” in the Theater Player library and open this folder.
        You can delete this file. When the folder is empty, it no longer appears in the Files app, \
        so Theater Player puts this file back the next time you open it.

        """)
    }

    /// フォルダが空なら案内を置く。何か入っていれば何もしない（消された案内も、ほかのファイルがあれば置き直さない）。
    /// 隠しファイル（.DS_Store など）は「ファイル」App に出ないので、それだけなら空とみなす
    static func prepare(_ folder: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first) {
        guard let folder else {
            return
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        guard contents?.isEmpty ?? true else {
            return
        }
        try? Data(guideText.utf8).write(to: folder.appendingPathComponent(guideName), options: .atomic)
    }
}
