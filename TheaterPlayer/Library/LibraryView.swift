//
//  LibraryView.swift
//  TheaterPlayer
//
//  ライブラリ（最初のウィンドウ）。ファイル・写真から動画や音楽を選び、映画館に入って再生する。最近の一覧から続きを再生できる。
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var importing = false
    @State private var photoItem: PhotosPickerItem?
    @State private var loadingPhoto = false

    var body: some View {
        @Bindable var appModel = appModel
        NavigationStack {
            VStack(spacing: 24) {
                header
                actions
                RecentList { item in
                    Task { await play { await appModel.player.open(item) } }
                }
            }
            .padding(36)
            .navigationTitle("Theater Player")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result {
                Task { await play { await appModel.player.open(url: url) } }
            }
        }
        .fileImporter(isPresented: $appModel.requestSubtitleFile, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result {
                Task {
                    await appModel.player.loadSubtitles(from: url)
                    closeIfInTheater()
                }
            }
        }
        .onChange(of: photoItem) {
            guard let photoItem else {
                return
            }
            Task { await playPhoto(photoItem) }
        }
        .onOpenURL { url in
            Task { await play { await appModel.player.open(url: url) } }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("映画館の大きなスクリーンで、手元の動画と音楽を")
                .font(.title3)
            Text("MKV・MP4・AVI・WMV・TS などの動画と、FLAC・MP3・AAC・WAV などの音楽を再生できます")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var actions: some View {
        let photoTitle = loadingPhoto ? String(localized: "読み込み中…") : String(localized: "写真から選ぶ")
        return HStack(spacing: 16) {
            Button {
                importing = true
            } label: {
                Label("ファイルを選ぶ", systemImage: "folder")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            PhotosPicker(selection: $photoItem, matching: .videos) {
                Label(photoTitle, systemImage: "photo.on.rectangle")
                    .frame(minWidth: 180)
            }
            .disabled(loadingPhoto)
            Button {
                Task { await enterTheater() }
            } label: {
                Label("映画館に入る", systemImage: "theatermasks")
                    .frame(minWidth: 180)
            }
            .disabled(appModel.immersiveSpaceState == .inTransition)
        }
        .controlSize(.large)
    }

    // MARK: - 再生と映画館

    /// 映画館に入ってから、open でファイルを開いて再生する
    private func play(_ open: () async -> Void) async {
        await enterTheater()
        await open()
    }

    private func playPhoto(_ item: PhotosPickerItem) async {
        loadingPhoto = true
        defer {
            loadingPhoto = false
            photoItem = nil
        }
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
            return
        }
        await play { await appModel.player.open(url: movie.url) }
    }

    /// 映画館（ImmersiveSpace）を開き、ライブラリのウィンドウを閉じる
    private func enterTheater() async {
        switch appModel.immersiveSpaceState {
        case .open:
            closeIfInTheater()
        case .closed:
            appModel.immersiveSpaceState = .inTransition
            switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
            case .opened:
                closeIfInTheater()
            default:
                appModel.immersiveSpaceState = .closed
            }
        case .inTransition:
            break
        }
    }

    private func closeIfInTheater() {
        if appModel.immersiveSpaceState != .closed {
            dismissWindow(id: appModel.libraryWindowID)
        }
    }
}

/// 最近再生したファイル
struct RecentList: View {
    @Environment(AppModel.self) private var appModel
    let open: (RecentItems.Item) -> Void

    var body: some View {
        let items = appModel.recents.items
        if items.isEmpty {
            ContentUnavailableView(
                "まだ再生したファイルはありません",
                systemImage: "clock",
                description: Text("「ファイルを選ぶ」から、iCloud Drive や外部ストレージの動画・音楽を開けます")
            )
        } else {
            List {
                Section("最近再生したもの") {
                    ForEach(items) { item in
                        Button {
                            open(item)
                        } label: {
                            row(item)
                        }
                        .swipeActions {
                            Button("削除", role: .destructive) { appModel.recents.remove(item) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: RecentItems.Item) -> some View {
        HStack {
            Image(systemName: item.isAudioOnly ? "music.note" : "film")
                .frame(width: 32)
            VStack(alignment: .leading) {
                Text(item.name).lineLimit(1)
                if let resume = item.resumePosition {
                    Text("続きから \(TimeFormat.clock(resume))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let duration = item.duration, duration > 0 {
                ProgressView(value: min(item.position, duration), total: duration).frame(width: 120)
            }
        }
    }
}

/// 写真ライブラリの動画（一時的な場所にコピーして開く）
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: received.file, to: target)
            return Self(url: target)
        }
    }
}
