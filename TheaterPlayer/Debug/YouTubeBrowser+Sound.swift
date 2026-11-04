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
        sound?.setActive(active)
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
                let report = sound.report()
                self?.soundReport = report
                Diagnostics.log("YouTube の音 \(report.logDescription) page=\(self?.soundPage?.logDescription ?? "なし")")
            }
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
            // 読み込み直したページに、スイッチの状態を渡し直す
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

    init(message: [String: Any]) {
        enabled = (message["enabled"] as? NSNumber)?.boolValue ?? false
        buffers = (message["buffers"] as? NSNumber)?.intValue ?? 0
        active = message["active"] as? String ?? ""
        muted = (message["muted"] as? NSNumber)?.boolValue ?? false
    }

    var logDescription: String {
        "enabled=\(enabled) buffers=\(buffers) active=\(active.isEmpty ? "なし" : active) muted=\(muted)"
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
            "problem=\(problem.isEmpty ? "なし" : problem)"
        ]
        return values.joined(separator: " ")
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
