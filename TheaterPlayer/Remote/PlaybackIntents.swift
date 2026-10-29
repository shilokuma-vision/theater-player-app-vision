//
//  PlaybackIntents.swift
//  TheaterPlayer
//
//  Siri・ショートカットの App から使う再生の操作（App Intents）。どれも PlayerCommand を AppModel.perform(_:) に渡すだけ。
//  AudioPlaybackIntent なので、アプリを前に出さずに、アプリのプロセスの中で動く。
//  映画館で動画・音楽を開いていなければ、何もせずにそう答える。閉じる・消すのような取り消せない操作は作らない。
//

import AppIntents

/// 戻す・進む長さ（App Shortcuts のフレーズに入れられる引数は AppEnum か AppEntity だけなので、秒数は選択肢から選ぶ）
nonisolated enum SkipAmount: Int, AppEnum {
    case tenSeconds = 10
    case thirtySeconds = 30
    case oneMinute = 60
    case fiveMinutes = 300

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "長さ")
    static let caseDisplayRepresentations: [SkipAmount: DisplayRepresentation] = [
        .tenSeconds: "10 秒",
        .thirtySeconds: "30 秒",
        .oneMinute: "1 分",
        .fiveMinutes: "5 分"
    ]

    var seconds: Double {
        Double(rawValue)
    }
}

/// 操作を行い、Siri の返事を返す（映画館で動画・音楽を開いていなければ、何もせずにそう答える）
@MainActor
private func performPlayback(
    _ command: PlayerCommand,
    on appModel: AppModel,
    done: LocalizedStringResource
) -> some IntentResult & ProvidesDialog {
    guard appModel.player.hasPlayback else {
        return .result(dialog: "映画館で動画・音楽を再生していません。")
    }
    appModel.perform(command)
    return .result(dialog: IntentDialog(done))
}

struct PausePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "一時停止"
    static let description = IntentDescription("映画館で再生している動画・音楽を一時停止します。")
    @Dependency private var appModel: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        performPlayback(.pause, on: appModel, done: "一時停止しました。")
    }
}

struct ResumePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "再生"
    static let description = IntentDescription("映画館で止めている動画・音楽を再生します。")
    @Dependency private var appModel: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        performPlayback(.play, on: appModel, done: "再生します。")
    }
}

struct SkipBackwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "戻す"
    static let description = IntentDescription("映画館で再生している動画・音楽を、指定した長さだけ戻します。")
    @Parameter(title: "長さ", default: .tenSeconds) var amount: SkipAmount
    @Dependency private var appModel: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$amount)戻す")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        performPlayback(.skip(by: -amount.seconds), on: appModel, done: "戻しました。")
    }
}

struct SkipForwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "進む"
    static let description = IntentDescription("映画館で再生している動画・音楽を、指定した長さだけ進めます。")
    @Parameter(title: "長さ", default: .tenSeconds) var amount: SkipAmount
    @Dependency private var appModel: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$amount)進む")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        performPlayback(.skip(by: amount.seconds), on: appModel, done: "進めました。")
    }
}

struct NextChapterIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "次のチャプター"
    static let description = IntentDescription("映画館で再生している動画の、次のチャプターへ移ります。")
    @Dependency private var appModel: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        performPlayback(.nextChapter, on: appModel, done: "次のチャプターへ移りました。")
    }
}

struct PreviousChapterIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "前のチャプター"
    static let description = IntentDescription("映画館で再生している動画の、前のチャプター（今のチャプターの始まり）へ移ります。")
    @Dependency private var appModel: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        performPlayback(.previousChapter, on: appModel, done: "前のチャプターへ移りました。")
    }
}

/// Siri のフレーズ（どれもアプリの名前を含める。システムの決まり）。ショートカットの App・Spotlight にも出る
struct TheaterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PausePlaybackIntent(),
            phrases: ["\(.applicationName)を一時停止", "\(.applicationName)を止めて"],
            shortTitle: "一時停止",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: ["\(.applicationName)を再生", "\(.applicationName)を再開"],
            shortTitle: "再生",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: SkipBackwardIntent(),
            phrases: ["\(.applicationName)で\(\.$amount)戻して", "\(.applicationName)を戻して"],
            shortTitle: "戻す",
            systemImageName: "gobackward"
        )
        AppShortcut(
            intent: SkipForwardIntent(),
            phrases: ["\(.applicationName)で\(\.$amount)進めて", "\(.applicationName)を進めて"],
            shortTitle: "進む",
            systemImageName: "goforward"
        )
        AppShortcut(
            intent: NextChapterIntent(),
            phrases: ["\(.applicationName)で次のチャプター"],
            shortTitle: "次のチャプター",
            systemImageName: "forward.end"
        )
        AppShortcut(
            intent: PreviousChapterIntent(),
            phrases: ["\(.applicationName)で前のチャプター"],
            shortTitle: "前のチャプター",
            systemImageName: "backward.end"
        )
    }
}
