//
//  YouTubeAudioSession.swift
//  TheaterPlayer
//
//  デバッグ用（デバッグのビルドだけ）：「映画館の音響に通す」のあいだの、アプリの音声のセッションの様子と、有効にし直す操作。
//  実機（visionOS 27.0）で、スイッチを入れると空間オーディオの描画が止まった（音源 0 本）。ページの <video> を消音したこと・
//  WebKit の再生・音声のセッションを有効にしていなかったこと（手元のファイルを開くまでは有効にしない）のどれが効いているかを
//  見分けるため、カテゴリ・中断などの知らせを表示とログに出す。
//

#if DEBUG
import AVFAudio
import Foundation
import Observation
import TheaterMedia

@MainActor
@Observable
final class YouTubeAudioSession {
    /// いちばん新しい知らせ（中断・経路の変更・メディアのサービスの再起動）
    private(set) var lastEvent = ""
    /// ほかの音と混ぜる設定にしたか（切ったら戻す）
    private(set) var isMixing = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let session = AVAudioSession.sharedInstance()
        observe(AVAudioSession.interruptionNotification, session: session) { info in
            let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let reason = (info?[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap(AVAudioSession.InterruptionReason.init)
            let reasonText = reason.map { "理由 \($0.rawValue)" } ?? ""
            return type == .began ? "中断が始まった \(reasonText)" : "中断が終わった"
        }
        observe(AVAudioSession.routeChangeNotification, session: session) { info in
            let reason = (info?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            return "経路が変わった（理由 \(reason)）"
        }
        observe(AVAudioSession.mediaServicesWereResetNotification, session: session) { _ in
            "メディアのサービスが再起動した"
        }
    }

    /// カテゴリ・モード・混ぜるか・ほかの音が鳴っているか
    var summary: String {
        let session = AVAudioSession.sharedInstance()
        let category = session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
        let mode = session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")
        let mixing = session.categoryOptions.contains(.mixWithOthers) ? "ほかと混ぜる" : "ほかと混ぜない"
        let others = session.isOtherAudioPlaying ? "ほかの音あり" : "ほかの音なし"
        return "\(category)・\(mode)・\(mixing)・\(others)"
    }

    /// 音声のセッションを有効にし直す。mixing なら、ほかの音（WebKit の再生）と混ぜる設定にしてから。結果の説明を返す
    @discardableResult
    func activate(mixing: Bool) -> String {
        let session = AVAudioSession.sharedInstance()
        do {
            if mixing {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                isMixing = true
            }
            try session.setActive(true)
            return mixing ? "ほかと混ぜる設定にして有効にした" : "有効にした"
        } catch {
            return "有効にできない（\(error.localizedDescription)）"
        }
    }

    /// 混ぜる設定にしていたら、アプリの元の設定（.playback。ほかのアプリの音を止める。NowPlaying）に戻す
    func restore() {
        guard isMixing else {
            return
        }
        isMixing = false
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            lastEvent = "元に戻せない（\(error.localizedDescription)）"
        }
    }

    private func observe(
        _ name: Notification.Name,
        session: AVAudioSession,
        describe: @escaping @Sendable ([AnyHashable: Any]?) -> String
    ) {
        let observer = NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) { [weak self] note in
            let text = describe(note.userInfo)
            Diagnostics.log("YouTube の音：音声のセッション \(text)")
            Task { @MainActor in
                self?.lastEvent = text
            }
        }
        observers.append(observer)
    }
}
#endif
