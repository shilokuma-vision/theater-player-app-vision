//
//  PrivacyManifestTests.swift
//  TheaterPlayerTests
//
//  アプリに入れたプライバシーマニフェスト（PrivacyInfo.xcprivacy）が読めて、理由の申告が要る API の申告が揃っているか。
//

import Foundation
import Testing

struct PrivacyManifestTests {
    /// アプリのバイナリが参照する、理由の申告が要る API のカテゴリと理由（調べ方は README の「プライバシーマニフェスト」）
    static let expectedReasons: [String: Set<String>] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
        // FFmpeg の stat・fstat・lstat
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1", "3B52.1"],
        // TheaterMedia の mach_absolute_time
        "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1", "8FFB.1"]
    ]

    func manifest() throws -> [String: Any] {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), "PrivacyInfo.xcprivacy がアプリに入っていない")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: Any])
    }

    /// カテゴリごとに 1 つずつ、決めた理由で申告している
    @Test func declaresReasonsForRequiredReasonAPIs() throws {
        let types = try #require(manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: Set<String>] = [:]
        for type in types {
            let category = try #require(type["NSPrivacyAccessedAPIType"] as? String)
            let codes = try #require(type["NSPrivacyAccessedAPITypeReasons"] as? [String])
            #expect(reasons[category] == nil, "\(category) を 2 回申告している")
            #expect(!codes.isEmpty, "\(category) に理由が無い")
            reasons[category] = Set(codes)
        }
        #expect(reasons == Self.expectedReasons)
    }
}
