//
//  LicensesView.swift
//  TheaterPlayer
//
//  ライセンス（ライブラリのウィンドウから開く）。使っているオープンソースのソフトウェアと、この版のソースの入手先。
//

import SwiftUI

struct LicensesView: View {
    var body: some View {
        List {
            Section {
                Text(
                    """
                    このアプリは、次のオープンソースのソフトウェアを使っています。\
                    FFmpeg は GNU Lesser General Public License 2.1 以降で配布されており、このアプリに静的にリンクしています。\
                    この版のソース（アプリ・FFmpeg を作るスクリプトとパッチ）と、FFmpeg・dav1d のソースの配布物は、\
                    GitHub の Release から入手できます。FFmpeg を差し替えて、このアプリを作り直すことができます。
                    """
                )
                .font(.callout)
                Link(destination: OpenSourceLicenses.release) {
                    Label("この版（\(OpenSourceLicenses.appVersion)）のソース", systemImage: "arrow.down.doc")
                }
            }
            Section("ソフトウェア") {
                ForEach(OpenSourceLicenses.components) { component in
                    NavigationLink {
                        LicenseDetail(component: component)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(component.name) \(component.version)").font(.headline)
                            Text(component.license).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("ライセンス")
    }
}

/// 1 つのソフトウェアの説明と、ライセンスの全文
struct LicenseDetail: View {
    let component: OpenSourceComponent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(component.name) \(component.version)").font(.title2.weight(.semibold))
                    Text(component.license).font(.headline)
                    Text(component.copyright).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(component.usage)
                Link(destination: component.source) {
                    Label("元のソース", systemImage: "link")
                }
                Divider()
                Text(component.licenseText ?? String(localized: "ライセンスの全文を読み込めませんでした"))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(component.name)
    }
}
