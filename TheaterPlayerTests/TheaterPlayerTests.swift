//
//  TheaterPlayerTests.swift
//  TheaterPlayerTests
//
//  Created by 村石 拓海 on 2024/05/12.
//

import Foundation
import Testing
@testable import TheaterPlayer

struct TheaterPlayerTests {
    /// Configs/Project.xcconfig の MARKETING_VERSION が「x.y.z」形式で Info.plist に反映されていることを確認する
    @Test
    func marketingVersionIsSemanticVersion() throws {
        let version = try #require(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
        let components = version.split(separator: ".")
        #expect(components.count == 3, "MARKETING_VERSION は x.y.z 形式で指定する: \(version)")
        #expect(components.allSatisfy { Int($0) != nil }, "各要素は整数で指定する: \(version)")
    }

    /// CURRENT_PROJECT_VERSION が正の整数として Info.plist に反映されていることを確認する
    @Test
    func buildNumberIsPositiveInteger() throws {
        let build = try #require(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
        let number = try #require(Int(build), "CURRENT_PROJECT_VERSION は整数で指定する: \(build)")
        #expect(number > 0)
    }

    /// 輸出の申告（暗号）を Info.plist で済ませ、アップロードのたびに App Store Connect で聞かれないようにする。
    /// FFmpeg の AES などは、暗号化されたメディア（MP4 の CENC・ASF・OMA など）を復号するデマクサーだけが使い、通信もしないので、
    /// 免除の範囲として NO にしている。通信や暗号を使う機能を足したら見直す
    @Test
    func declaresNoNonExemptEncryption() throws {
        let value = try #require(
            Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool,
            "Info.plist に ITSAppUsesNonExemptEncryption が無い"
        )
        #expect(value == false)
    }
}
