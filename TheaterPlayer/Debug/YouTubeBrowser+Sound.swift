//
//  YouTubeBrowser+Sound.swift
//  TheaterPlayer
//
//  デバッグ用（デバッグのビルドだけ）：YouTube の「映画館の音響に通す」のスイッチと、ページのスクリプト（YouTubeSoundScript）との
//  やりとり。入れているあいだは、ページが MSE に入れる音声と <video> の時計を受け、YouTubeSound で映画館の音響から鳴らす。
//  YouTube の利用規約は、音や映像を切り離したり手を加えたりすることを禁じている。これは確認用で、利用者の判断で作った。配らない。
//

#if DEBUG
import Foundation
import TheaterMedia
import WebKit

extension YouTubeBrowser {
    /// スイッチの状態を、ページのスクリプトと音源に渡す（入れた・切った・ページを読み込んだ・閉じた）
    func applySoundRoute() {
        let active = routesSoundThroughTheater && page != nil
        let wasActive = sound?.isActive ?? false
        sound?.setActive(active)
        sentOriginalMuted = nil
        if active != wasActive {
            let troubled = soundGuard.heals > 0 || soundGuard.silentSeconds > 0
            soundGuard = YouTubeSoundGuard()
            soundNotes = []
            if active {
                // 音声のセッションは、手元のファイルを開くまで有効にしない。YouTube だけ見ているときのために、ここで有効にする
                soundNotes.append("音声のセッションを\(soundSession.activate(mixing: false))")
            } else {
                // 混ぜる設定にしていたら戻す。通しているあいだに空間オーディオが止まったなら、手元のファイルの音を鳴らせるよう、
                // 音源を鳴らし直す（うまく鳴っていたときは触らない）
                soundSession.restore()
                if troubled {
                    _ = restartSpeakers?()
                }
            }
        }
        followReport(active)
        guard let page else {
            soundPage = nil
            return
        }
        let enabled = routesSoundThroughTheater
        Task {
            _ = try? await page.callJavaScript(
                YouTubeSoundScript.setEnabled,
                arguments: ["enabled": enabled],
                contentWorld: YouTubeSoundScript.world
            )
        }
    }

    /// 通しているあいだ、1 秒ごとに様子を読む
    private func followReport(_ active: Bool) {
        guard active else {
            reportTask?.cancel()
            reportTask = nil
            soundReport = nil
            return
        }
        guard reportTask == nil, let sound else {
            return
        }
        reportTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                // 待っているあいだに切った・閉じた
                guard !Task.isCancelled else {
                    return
                }
                guard let self else {
                    return
                }
                let report = sound.report()
                soundReport = report
                follow(report)
                Diagnostics.log(
                    "YouTube の音 \(report.logDescription) guard=\(soundGuard.logDescription) " +
                        "session=\(soundSession.summary) event=\(soundSession.lastEvent) page=\(soundPage?.logDescription ?? "なし")"
                )
            }
        }
    }

    /// 1 秒ごとの様子から、空間オーディオを鳴らし直すか・ページの元の音を消すかを決める
    private func follow(_ report: YouTubeSound.Report) {
        let decoding = !report.format.isEmpty && report.problem.isEmpty
        if case let .heal(attempt) = soundGuard.update(rendering: report.renders > 0, decoding: decoding) {
            // 1 回目は有効にし直すだけ。2 回目からは、ほかの音（WebKit の再生）と混ぜる設定にする
            let result = soundSession.activate(mixing: attempt >= 2)
            let stopped = restartSpeakers?() ?? -1
            let note = "鳴らし直した（\(attempt) 回目）：音声のセッションを\(result)・止まっていた音源 \(stopped) 本"
            soundNotes.append(note)
            Diagnostics.log("YouTube の音 \(note)")
        }
        let muted = soundGuard.mutesOriginal
        guard muted != sentOriginalMuted, let page else {
            return
        }
        sentOriginalMuted = muted
        Task {
            _ = try? await page.callJavaScript(
                YouTubeSoundScript.setOriginalMuted,
                arguments: ["muted": muted],
                contentWorld: YouTubeSoundScript.world
            )
        }
    }

    /// ページのスクリプトから届いた物（YouTubeSoundScript.source の type）
    func receiveSoundMessage(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else {
            return
        }
        switch type {
        case "state":
            soundPage = YouTubeSoundPageState(message: message)
        case "ready":
            // 読み込み直したページに、スイッチの状態を渡し直す（元の音を消してよいかは、次の様子で渡し直す）
            if routesSoundThroughTheater {
                applySoundRoute()
            }
        default:
            sound?.receive(message)
        }
    }
}

/// ページのスクリプトの様子（YouTubeSoundScript の state）
struct YouTubeSoundPageState: Equatable {
    var enabled: Bool
    /// 写している音声の入れ物の数
    var buffers: Int
    /// 送っている音声の入れ物の形式（audio/webm; codecs="opus" など。見つからなければ空）
    var active: String
    /// ページの元の音を消している
    var muted: Bool
    /// アプリが、ページの元の音を消してよいと言っている
    var mutesOriginal: Bool

    init(message: [String: Any]) {
        enabled = (message["enabled"] as? NSNumber)?.boolValue ?? false
        buffers = (message["buffers"] as? NSNumber)?.intValue ?? 0
        active = message["active"] as? String ?? ""
        muted = (message["muted"] as? NSNumber)?.boolValue ?? false
        mutesOriginal = (message["mutesOriginal"] as? NSNumber)?.boolValue ?? false
    }

    var logDescription: String {
        "enabled=\(enabled) buffers=\(buffers) active=\(active.isEmpty ? "なし" : active) muted=\(muted) mutesOriginal=\(mutesOriginal)"
    }
}

extension YouTubeSound.Report {
    var logDescription: String {
        let values = [
            "format=\(format.isEmpty ? "なし" : format)",
            "playing=\(isPlaying)",
            "ahead=\(String(format: "%.1f", bufferedAhead))s",
            "lead=\(String(format: "%.1f", lead))ms",
            "offset=\(String(format: "%.1f", offset))ms",
            "jitter=\(String(format: "%.1f", clockJitter))ms",
            "resyncs=\(resyncs)",
            "missing=\(String(format: "%.0f", missing))ms",
            "appends=\(appends)",
            "bytes=\(bytes)",
            "peak=\(String(format: "%.3f", peak))",
            "readers=\(readers)",
            "renders=\(String(format: "%.0f", renders))/s",
            "problem=\(problem.isEmpty ? "なし" : problem)"
        ]
        return values.joined(separator: " ")
    }
}

extension YouTubeSoundGuard {
    var logDescription: String {
        "mutesOriginal=\(mutesOriginal) heals=\(heals) gaveUp=\(gaveUp) silent=\(silentSeconds)s"
    }
}

/// ページのスクリプトからの知らせを、YouTubeBrowser へ渡す（WKUserContentController は受け手を強く持つので、browser は弱く持つ）
final class YouTubeSoundReceiver: NSObject, WKScriptMessageHandler {
    private weak var browser: YouTubeBrowser?

    init(browser: YouTubeBrowser) {
        self.browser = browser
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        browser?.receiveSoundMessage(message.body)
    }
}
#endif
