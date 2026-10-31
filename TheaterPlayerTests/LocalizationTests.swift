//
//  LocalizationTests.swift
//  TheaterPlayerTests
//
//  String Catalog（*.xcstrings）の訳し漏れ。どのキーにも元の言語（en）の文言と、訳す言語の訳があり、
//  %@・%lld などの数と種類が元の文言と合うか。アプリに入った訳（ビルドで書き出した .strings）が catalog と同じかも確かめる。
//  catalog そのものはアプリに入らないので、リポジトリのファイルを読む（Simulator のテストはホストのファイルを読める）。
//

import Foundation
import Testing

nonisolated struct LocalizationTests {
    /// 訳す言語（元の言語の en を除く）。言語を足したら、ここにも足す
    static let languages = ["ja"]

    /// リポジトリの String Catalog と、その訳を引くアプリの中のバンドル
    static let catalogs: [CatalogFile] = [
        CatalogFile(path: "TheaterPlayer/Localizable.xcstrings", bundleName: nil),
        CatalogFile(path: "Packages/TheaterMedia/Sources/TheaterMedia/Localizable.xcstrings", bundleName: "TheaterMedia_TheaterMedia")
    ]

    /// リポジトリの根（このファイルは TheaterPlayerTests/ の下にある）
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    @Test(arguments: catalogs)
    func everyKeyHasSourceAndTranslations(file: CatalogFile) throws {
        let catalog = try file.load()
        #expect(catalog.sourceLanguage == "en")
        #expect(!catalog.strings.isEmpty)
        for (key, entry) in catalog.translatableStrings {
            let source = try #require(entry.sourceValue(for: key), "\(file.path)：「\(key)」に元の言語（en）の文言が無い")
            for language in Self.languages {
                let units = entry.localizations?[language]?.units ?? []
                #expect(!units.isEmpty, "\(file.path)：「\(key)」に \(language) の訳が無い")
                for unit in units {
                    #expect(unit.state == "translated", "\(file.path)：「\(key)」の \(language) の訳が \(unit.state)")
                    #expect(!unit.value.isEmpty, "\(file.path)：「\(key)」の \(language) の訳が空")
                    #expect(
                        FormatSpecifier.list(in: unit.value) == FormatSpecifier.list(in: source),
                        "\(file.path)：「\(key)」の \(language) の訳「\(unit.value)」の %@ などが、元の文言と合わない"
                    )
                }
            }
        }
    }

    /// アプリに入った訳が、catalog の訳と同じ（ビルドで catalog が書き出され、バンドルから引ける）
    @Test(arguments: catalogs)
    func bundleContainsTranslations(file: CatalogFile) throws {
        let catalog = try file.load()
        let bundle = try #require(file.bundle(), "\(file.path) の訳を入れたバンドルがアプリに無い")
        for language in ["en"] + Self.languages {
            let path = try #require(bundle.path(forResource: language, ofType: "lproj"), "\(file.path)：\(language).lproj が無い")
            let localized = try #require(Bundle(path: path))
            for (key, entry) in catalog.translatableStrings {
                let expected = language == "en" ? entry.sourceValue(for: key) : entry.localizations?[language]?.stringUnit?.value
                // 数で文言を変える（variations）ものは .stringsdict に入り、ここでは比べられない
                guard let expected, entry.localizations?[language]?.variations == nil else {
                    continue
                }
                let value = localized.localizedString(forKey: key, value: key, table: "Localizable")
                #expect(value == expected, "\(file.path)：\(language) の「\(key)」")
            }
        }
    }

    @Test func formatSpecifiersKeepTypeAndOrder() {
        #expect(FormatSpecifier.list(in: "Row %@, Seat %lld") == ["@", "lld"])
        #expect(FormatSpecifier.list(in: "%2$lld 番 %1$@ 列") == ["@", "lld"])
        #expect(FormatSpecifier.list(in: "100%% %.2f") == ["f"])
        #expect(FormatSpecifier.list(in: "なし").isEmpty)
    }
}

/// リポジトリの String Catalog 1 つ
nonisolated struct CatalogFile: Sendable, CustomTestStringConvertible {
    /// リポジトリの根からのパス
    let path: String
    /// 訳を入れるバンドル（Swift Package のリソースのバンドルの名前。nil ならアプリ）
    let bundleName: String?

    var testDescription: String { path }

    func load() throws -> StringCatalog {
        try JSONDecoder().decode(StringCatalog.self, from: Data(contentsOf: LocalizationTests.root.appending(path: path)))
    }

    func bundle() -> Bundle? {
        guard let bundleName else {
            return .main
        }
        return Bundle.main.url(forResource: bundleName, withExtension: "bundle").flatMap(Bundle.init(url:))
    }
}

/// .xcstrings の中身（テストで使うところだけ）
nonisolated struct StringCatalog: Decodable {
    let sourceLanguage: String
    let strings: [String: Entry]

    /// 訳すキー（訳さない印のもの・コードで使わなくなったものを除く）
    var translatableStrings: [(key: String, entry: Entry)] {
        strings.filter { $0.value.shouldTranslate != false && $0.value.extractionState != "stale" }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, entry: $0.value) }
    }

    struct Entry: Decodable {
        let extractionState: String?
        let shouldTranslate: Bool?
        let localizations: [String: Localization]?

        /// 元の言語（en）の文言。キーと違う文言を持つもの（String(localized:defaultValue:) など）は en の訳にある
        func sourceValue(for key: String) -> String? {
            if let value = localizations?["en"]?.stringUnit?.value {
                return value
            }
            return extractionState == "extracted_with_value" || extractionState == "manual" ? nil : key
        }
    }

    struct Localization: Decodable {
        let stringUnit: StringUnit?
        /// 数・端末で文言を変えるとき（plural の one・other など）
        let variations: [String: [String: Self]]?

        /// この言語の文言のすべて
        var units: [StringUnit] {
            (stringUnit.map { [$0] } ?? []) + (variations ?? [:]).values.flatMap { $0.values.flatMap(\.units) }
        }
    }

    struct StringUnit: Decodable {
        let state: String
        let value: String
    }
}

/// 文言の中の %@・%lld などの並び（位置つきの %1$@ は位置の順に並べ直す）
nonisolated enum FormatSpecifier {
    static func list(in text: String) -> [String] {
        // 位置（1$ など）・長さ（ll など）・変換（@ など）
        let pattern = #/%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA%])/#
        var next = 1
        var found: [(position: Int, type: String)] = []
        for match in text.matches(of: pattern) {
            let conversion = String(match.output.3)
            guard conversion != "%" else {
                continue
            }
            let position = match.output.1.flatMap { Int($0) } ?? next
            next += 1
            found.append((position, String(match.output.2 ?? "") + conversion))
        }
        return found.sorted { $0.position < $1.position }.map(\.type)
    }
}
