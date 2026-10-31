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
                    This app uses the following open source software. \
                    FFmpeg is distributed under the GNU Lesser General Public License version 2.1 or later \
                    and is statically linked into this app. \
                    The source code of this version (the app, and the scripts and patches that build FFmpeg) \
                    and the source distributions of FFmpeg and dav1d are available from the GitHub release. \
                    You can replace FFmpeg and rebuild this app.
                    """
                )
                .font(.callout)
                Link(destination: OpenSourceLicenses.release) {
                    Label("Source Code of This Version (\(OpenSourceLicenses.appVersion))", systemImage: "arrow.down.doc")
                }
            }
            Section("Software") {
                ForEach(OpenSourceLicenses.components) { component in
                    NavigationLink {
                        LicenseDetail(component: component)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: "\(component.name) \(component.version)").font(.headline)
                            Text(component.license).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Licenses")
    }
}

/// 1 つのソフトウェアの説明と、ライセンスの全文
struct LicenseDetail: View {
    let component: OpenSourceComponent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "\(component.name) \(component.version)").font(.title2.weight(.semibold))
                    Text(component.license).font(.headline)
                    Text(component.copyright).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(component.usage)
                Link(destination: component.source) {
                    Label("Original Source Code", systemImage: "link")
                }
                Divider()
                Text(component.licenseText ?? String(localized: "Couldn’t load the full license text."))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(component.name)
    }
}
