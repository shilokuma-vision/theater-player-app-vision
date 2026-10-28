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
    /// ファイルの選択で選ぶ物（fileImporter は 1 つの View に 1 つしか効かないので、1 つを使い分ける）
    private enum ImportTarget {
        case media, subtitles
    }

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var importing = false
    @State private var importTarget = ImportTarget.media
    @State private var photoItem: PhotosPickerItem?
    @State private var loadingPhoto = false

    var body: some View {
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
            .toolbar {
                // LGPL・BSD が求める、使っているオープンソースのソフトウェアの表示
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        LicensesView()
                    } label: {
                        Label("ライセンス", systemImage: "doc.text")
                    }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result {
                imported(url)
            }
        }
        // 映画館の中から字幕ファイルを頼まれたら、同じ fileImporter で選ぶ（ウィンドウを開いたときに頼まれていることもある）
        .onChange(of: appModel.requestSubtitleFile, initial: true) {
            guard appModel.requestSubtitleFile else {
                return
            }
            appModel.requestSubtitleFile = false
            importTarget = .subtitles
            importing = true
        }
        .onAppear {
            appModel.isLibraryOpen = true
        }
        .onDisappear {
            appModel.isLibraryOpen = false
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
                importTarget = .media
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

    private func imported(_ url: URL) {
        switch importTarget {
        case .media:
            Task { await play { await appModel.player.open(url: url) } }
        case .subtitles:
            Task {
                await appModel.player.loadSubtitles(from: url)
                closeIfInTheater()
            }
        }
    }

    /// 映画館に入ってから、open でファイルを開いて再生する（入れなければ開かない。映画館が無いと操作できないため）
    private func play(_ open: () async -> Void) async {
        guard await enterTheater() else {
            return
        }
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
        await play { await appModel.player.open(url: movie.url, temporary: true) }
    }

    /// 映画館（ImmersiveSpace）を開き、ライブラリのウィンドウを閉じる。映画館に入れたら true
    @discardableResult
    private func enterTheater() async -> Bool {
        // 開け閉めの途中（「映画館を出る」で閉じている途中など）なら、終わるのを待つ（最大 5 秒）。
        // 閉じている途中で開くと、閉じたあとの片付けで、開いたファイルが閉じられる
        for _ in 0..<50 where appModel.immersiveSpaceState == .inTransition {
            try? await Task.sleep(for: .milliseconds(100))
        }
        switch appModel.immersiveSpaceState {
        case .open:
            closeIfInTheater()
            return true
        case .closed:
            appModel.immersiveSpaceState = .inTransition
            switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
            case .opened:
                closeIfInTheater()
                return true
            default:
                appModel.immersiveSpaceState = .closed
                return false
            }
        case .inTransition:
            return false
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

/// 写真ライブラリの動画（Caches/PickedMovies にコピーして開く。再生を閉じたら PlayerModel が消す）
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try Self.copy(received.file)
        }
    }

    /// 選ぶたびに別のフォルダーへコピーする（前の動画を閉じて消すときに、新しいコピーを消さない）。
    /// 前に選んだ物の残り（再生中にアプリが終わったときなど）は、ここで消す。再生中の物を消しても、開いているあいだは読める
    nonisolated private static func copy(_ file: URL) throws -> Self {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let folder = caches.appendingPathComponent("PickedMovies", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let target = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(file.lastPathComponent)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: target)
        return Self(url: target)
    }
}
