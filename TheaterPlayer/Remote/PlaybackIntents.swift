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

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Duration")
    // 言い換え（synonyms）は、Siri が数を文字（ten・十）や詰めた形（10 sec・10秒）で聞き取ったときのため
    static let caseDisplayRepresentations: [SkipAmount: DisplayRepresentation] = [
        .tenSeconds: DisplayRepresentation(title: "10 seconds", synonyms: ["ten seconds", "10 sec"]),
        .thirtySeconds: DisplayRepresentation(title: "30 seconds", synonyms: ["thirty seconds", "30 sec"]),
        .oneMinute: DisplayRepresentation(title: "1 minute", synonyms: ["one minute", "1 min"]),
        .fiveMinutes: DisplayRepresentation(title: "5 minutes", synonyms: ["five minutes", "5 min"])
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
        return .result(dialog: "Nothing is playing in the theater.")
    }
    appModel.perform(command)
    return .result(dialog: IntentDialog(done))
}

struct PausePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause"
    static let description = IntentDescription("Pauses the video or music playing in the theater.")
    @Dependency private var appModel: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        performPlayback(.pause, on: appModel, done: "Paused.")
    }
}

struct ResumePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play"
    static let description = IntentDescription("Plays the paused video or music in the theater.")
    @Dependency private var appModel: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        performPlayback(.play, on: appModel, done: "Playing.")
    }
}

struct SkipBackwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Back"
    static let description = IntentDescription("Skips the video or music playing in the theater back by the duration you choose.")
    @Parameter(title: "Duration", default: .tenSeconds) var amount: SkipAmount
    @Dependency private var appModel: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Skip back \(\.$amount)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        performPlayback(.skip(by: -amount.seconds), on: appModel, done: "Skipped back.")
    }
}

struct SkipForwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Skips the video or music playing in the theater forward by the duration you choose.")
    @Parameter(title: "Duration", default: .tenSeconds) var amount: SkipAmount
    @Dependency private var appModel: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Skip forward \(\.$amount)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        performPlayback(.skip(by: amount.seconds), on: appModel, done: "Skipped forward.")
    }
}

struct NextChapterIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Chapter"
    static let description = IntentDescription("Moves to the next chapter of the video playing in the theater.")
    @Dependency private var appModel: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        performPlayback(.nextChapter, on: appModel, done: "Moved to the next chapter.")
    }
}

struct PreviousChapterIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Chapter"
    static let description = IntentDescription(
        "Moves to the previous chapter (the start of the current chapter) of the video playing in the theater."
    )
    @Dependency private var appModel: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        performPlayback(.previousChapter, on: appModel, done: "Moved to the previous chapter.")
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
