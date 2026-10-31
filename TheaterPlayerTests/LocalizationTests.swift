//
//  LocalizationTests.swift
//  TheaterPlayerTests
//
//  String Catalog（*.xcstrings）の訳し漏れ。どのキーにも元の言語（en）の文言と、訳す言語の訳があり、
//  %@・%lld・${amount} などの数と種類が元の文言と合うか。アプリに入った訳（ビルドで書き出した .strings）が catalog と同じかも確かめる。
//  catalog そのものはアプリに入らないので、リポジトリのファイルを読む（Simulator のテストはホストのファイルを読める）。
//

import Foundation
import Testing

nonisolated struct LocalizationTests {
    /// 訳す言語（元の言語の en を除く）。言語を足したら、ここにも足す
    static let languages = ["ja", "zh-Hans", "zh-Hant", "ko", "de"]

    /// リポジトリの String Catalog と、その訳を引くアプリの中のバンドル
    static let catalogs: [CatalogFile] = [
        CatalogFile(path: "TheaterPlayer/Localizable.xcstrings", bundleName: nil),
        // Info.plist の文言（表示名・書類の種類の名前）
        CatalogFile(path: "TheaterPlayer/InfoPlist.xcstrings", bundleName: nil),
        // Siri のフレーズ（キーは最初のフレーズで、言語ごとに複数のフレーズを stringSet に持つ）
        CatalogFile(path: "TheaterPlayer/AppShortcuts.xcstrings", bundleName: nil),
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
            let sources = try #require(entry.sourceValues(for: key), "\(file.path)：「\(key)」に元の言語（en）の文言が無い")
            for language in Self.languages {
                let localization = entry.localizations?[language]
                let units = localization?.units ?? []
                #expect(!units.isEmpty, "\(file.path)：「\(key)」に \(language) の訳が無い")
                for unit in units {
                    #expect(unit.state == "translated", "\(file.path)：「\(key)」の \(language) の訳が \(unit.state)")
                    #expect(!unit.value.isEmpty, "\(file.path)：「\(key)」の \(language) の訳が空")
                    if localization?.stringSet != nil {
                        // Siri のフレーズ：どのフレーズもアプリの名前を 1 回だけ含み、元のフレーズに無い引数を使わない
                        let allowed = Set(sources.flatMap(Placeholder.list(in:)))
                        let used = Placeholder.list(in: unit.value)
                        #expect(used.filter { $0 == "applicationName" }.count == 1, "\(file.path)：「\(unit.value)」にアプリの名前が 1 回ではない")
                        #expect(Set(used).isSubset(of: allowed), "\(file.path)：「\(unit.value)」に元のフレーズに無い引数がある")
                    } else {
                        #expect(
                            FormatSpecifier.list(in: unit.value) == FormatSpecifier.list(in: sources[0])
                                && Placeholder.list(in: unit.value).sorted() == Placeholder.list(in: sources[0]).sorted(),
                            "\(file.path)：「\(key)」の \(language) の訳「\(unit.value)」の %@ などが、元の文言と合わない"
                        )
                    }
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
                let localization = entry.localizations?[language]
                // 数で文言を変える（variations）ものは .stringsdict に、Siri のフレーズ（stringSet）は App Intents のメタデータに入り、
                // ここでは比べられない
                guard localization?.variations == nil, localization?.stringSet == nil else {
                    continue
                }
                let expected = language == "en" ? entry.sourceValues(for: key)?.first : localization?.stringUnit?.value
                guard let expected else {
                    continue
                }
                let value = localized.localizedString(forKey: key, value: key, table: file.table)
                #expect(value == expected, "\(file.path)：\(language) の「\(key)」")
            }
        }
    }

    @Test func formatSpecifiersKeepTypeAndOrder() {
        #expect(FormatSpecifier.list(in: "Row %@, Seat %lld") == ["@", "lld"])
        #expect(FormatSpecifier.list(in: "%2$lld 番 %1$@ 列") == ["@", "lld"])
        #expect(FormatSpecifier.list(in: "100%% %.2f") == ["f"])
        #expect(FormatSpecifier.list(in: "なし").isEmpty)
        #expect(Placeholder.list(in: "${applicationName}で${amount}戻して") == ["applicationName", "amount"])
    }
}

/// リポジトリの String Catalog 1 つ
nonisolated struct CatalogFile: Sendable, CustomTestStringConvertible {
    /// リポジトリの根からのパス
    let path: String
    /// 訳を入れるバンドル（Swift Package のリソースのバンドルの名前。nil ならアプリ）
    let bundleName: String?

    var testDescription: String { path }

    /// 訳を引くときの表の名前（catalog のファイルの名前）
    var table: String {
        URL(filePath: path).deletingPathExtension().lastPathComponent
    }

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

        /// 元の言語（en）の文言（Siri のフレーズは複数）。キーと違う文言を持つもの（String(localized:defaultValue:)・Info.plist など）は
        /// en の訳にある
        func sourceValues(for key: String) -> [String]? {
            if let value = localizations?["en"]?.stringUnit?.value {
                return [value]
            }
            if let values = localizations?["en"]?.stringSet?.values, !values.isEmpty {
                return values
            }
            return extractionState == "extracted_with_value" || extractionState == "manual" ? nil : [key]
        }
    }

    struct Localization: Decodable {
        let stringUnit: StringUnit?
        /// 数・端末で文言を変えるとき（plural の one・other など）
        let variations: [String: [String: Self]]?
        /// Siri のフレーズ（AppShortcuts.xcstrings）
        let stringSet: StringSet?

        /// この言語の文言のすべて
        var units: [StringUnit] {
            (stringUnit.map { [$0] } ?? [])
                + (variations ?? [:]).values.flatMap { $0.values.flatMap(\.units) }
                + (stringSet.map { set in set.values.map { StringUnit(state: set.state, value: $0) } } ?? [])
        }
    }

    struct StringSet: Decodable {
        let state: String
        let values: [String]
    }

    struct StringUnit: Decodable {
        let state: String
        let value: String
    }
}

/// App Intents の文言の中の ${applicationName}・${amount} などの名前（出てくる順）
nonisolated enum Placeholder {
    static func list(in text: String) -> [String] {
        text.matches(of: #/\$\{(\w+)\}/#).map { String($0.output.1) }
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
