//
//  LicenseTests.swift
//  TheaterPlayerTests
//
//  ライセンスの画面（LGPL・BSD・MIT が求める表示）に出す物が、アプリに入っているか。
//

import Foundation
import Testing
@testable import TheaterPlayer

struct LicenseTests {
    /// どのソフトウェアも、ライセンスの全文をアプリから読める
    @Test func everyComponentHasItsLicenseText() throws {
        for component in OpenSourceLicenses.components {
            let text = try #require(component.licenseText, "\(component.name) のライセンスの全文が無い")
            #expect(!text.isEmpty)
        }
    }

    /// FFmpeg は LGPL 2.1 の全文、dav1d は BSD の著作権の表示を付ける
    @Test func licenseTextsMatchTheirLicenses() throws {
        let ffmpeg = try #require(OpenSourceLicenses.components.first { $0.name == "FFmpeg" }?.licenseText)
        #expect(ffmpeg.contains("GNU LESSER GENERAL PUBLIC LICENSE"))
        #expect(ffmpeg.contains("Version 2.1"))
        let dav1d = try #require(OpenSourceLicenses.components.first { $0.name == "dav1d" }?.licenseText)
        #expect(dav1d.contains("VideoLAN and dav1d authors"))
    }

    /// この版のソースの入手先は、アプリの版の Release
    @Test func releaseLinkUsesTheAppVersion() {
        #expect(!OpenSourceLicenses.appVersion.isEmpty)
        #expect(OpenSourceLicenses.release.absoluteString.hasSuffix("/releases/tag/v\(OpenSourceLicenses.appVersion)"))
    }
}
