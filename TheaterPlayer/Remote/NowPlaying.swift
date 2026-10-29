//
//  NowPlaying.swift
//  TheaterPlayer
//
//  システムの「再生中」（Now Playing）。コントロールセンター・AirPods・Siri・キーボードのメディアキーからの操作を
//  PlayerCommand として受け、再生中の物の題名・長さ・位置・ジャケットをシステムに見せる。
//  音は RealityKit の空間オーディオ（AudioGeneratorController）から出している。Now Playing のアプリになるには、
//  音声のセッションを .playback にして有効にする（.playback は、ほかのアプリの音を止める。映画館なのでそれでよい）。
//

import AVFAudio
import MediaPlayer
import TheaterMedia
import UIKit

final class NowPlaying {
    /// システムに見せる、再生中の物
    struct Item: Equatable {
        var title: String
        var artist: String?
        var album: String?
        /// 長さ（秒。分からなければ 0）
        var duration: Double
        /// 今の位置（秒）。システムは、これと速さから位置を進めて見せる
        var elapsed: Double
        /// 再生の速さ（止めている・データを待っているあいだは 0）
        var rate: Double
        var isAudioOnly: Bool
        /// チャプターの数（2 つ以上あれば、「次の曲」「前の曲」でチャプターを移れるようにする）
        var chapterCount: Int
    }

    /// コントロールセンター・AirPods の「進む」「戻る」の秒数（操作パネルのボタンと同じ）
    nonisolated static let skipForwardInterval: Double = 30
    nonisolated static let skipBackwardInterval: Double = 10

    /// 受けた操作の渡し先（AppModel.perform(_:)）
    private var perform: ((PlayerCommand) -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// 今見せているジャケット（同じ画像なら、作り直さない）
    private var artworkImage: CGImage?
    private var artwork: MPMediaItemArtwork?

    init() {
        // カテゴリは起動したときに決める（visionOS 26.5 の実機で、ボタンを押した直後に音声のセッションを設定すると、
        // そのあとの設定が効かなくなるという報告がある。Apple Developer Forums 828131）
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            Diagnostics.log("音声のセッションのカテゴリを設定できなかった：\(error)")
        }
    }

    // MARK: - 操作を受ける

    /// システムからの操作を受け始める（AppModel が 1 回だけ呼ぶ）。受けた操作は perform に渡す
    func connect(_ perform: @escaping (PlayerCommand) -> Void) {
        self.perform = perform
        let center = MPRemoteCommandCenter.shared()
        addTarget(center.playCommand) { _ in .play }
        addTarget(center.pauseCommand) { _ in .pause }
        addTarget(center.togglePlayPauseCommand) { _ in .togglePlay }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForwardInterval)]
        addTarget(center.skipForwardCommand) { event in
            .skip(by: (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipForwardInterval)
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBackwardInterval)]
        addTarget(center.skipBackwardCommand) { event in
            .skip(by: -((event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipBackwardInterval))
        }
        addTarget(center.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .seek(to: $0.positionTime) }
        }
        // 「次の曲」「前の曲」（AirPods の 2 回・3 回押しなど）は、チャプターの移動にする
        addTarget(center.nextTrackCommand) { _ in .nextChapter }
        addTarget(center.previousTrackCommand) { _ in .previousChapter }
        update(nil, artwork: nil)
        observeAudioSession()
    }

    /// command を受けたら、makeCommand で PlayerCommand に読み替えて渡す。
    /// システムがどのスレッドから呼んでも落ちないよう、受ける処理はどの actor にも属さない（@Sendable）ようにし、MainActor へ渡し直す
    private func addTarget(_ command: MPRemoteCommand, _ makeCommand: @escaping @Sendable (MPRemoteCommandEvent) -> PlayerCommand?) {
        command.addTarget { @Sendable [weak self] event in
            guard let playerCommand = makeCommand(event) else {
                return .commandFailed
            }
            self?.send(playerCommand)
            return .success
        }
    }

    nonisolated private func send(_ command: PlayerCommand) {
        Task { @MainActor [weak self] in
            self?.perform?(command)
        }
    }

    // MARK: - 音声のセッション

    /// 再生を始めるときに、音声のセッションを有効にする（Now Playing のアプリになる）
    func activate() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Diagnostics.log("音声のセッションを有効にできなかった：\(error)")
        }
    }

    /// 映画館を出たら、音声のセッションを止める（止めていたほかのアプリの音に、再開してよいと知らせる）
    func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Diagnostics.log("音声のセッションを止められなかった：\(error)")
        }
    }

    /// 電話・ほかのアプリの音などで中断されたとき、ヘッドホン（AirPods）が外れたときは、一時停止する
    private func observeAudioSession() {
        pause(on: AVAudioSession.interruptionNotification) { info in
            let value = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            return value.flatMap(AVAudioSession.InterruptionType.init) == .began
        }
        pause(on: AVAudioSession.routeChangeNotification) { info in
            let value = info?[AVAudioSessionRouteChangeReasonKey] as? UInt
            return value.flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable
        }
    }

    /// 音声のセッションから name の知らせが来て、shouldPause が true を返したら、一時停止する
    private func pause(on name: Notification.Name, when shouldPause: @escaping @Sendable ([AnyHashable: Any]?) -> Bool) {
        let session = AVAudioSession.sharedInstance()
        let observer = NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) { [weak self] note in
            if shouldPause(note.userInfo) {
                self?.send(.pause)
            }
        }
        observers.append(observer)
    }

    // MARK: - 再生中の物を見せる

    /// 再生中の物を見せる（nil なら消す）。開いた・再生／一時停止・シーク・速さを変えたときに呼ぶ（位置はシステムが進めるので、毎秒は呼ばない）
    func update(_ item: Item?, artwork image: CGImage?) {
        let commands = MPRemoteCommandCenter.shared()
        for command in [
            commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
            commands.skipForwardCommand, commands.skipBackwardCommand, commands.changePlaybackPositionCommand
        ] {
            command.isEnabled = item != nil
        }
        let hasChapters = (item?.chapterCount ?? 0) > 1
        commands.nextTrackCommand.isEnabled = hasChapters
        commands.previousTrackCommand.isEnabled = hasChapters
        let center = MPNowPlayingInfoCenter.default()
        guard let item else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info = Self.info(for: item)
        if let image {
            info[MPMediaItemPropertyArtwork] = mediaArtwork(for: image)
        }
        center.nowPlayingInfo = info
        center.playbackState = item.rate > 0 ? .playing : .paused
    }

    /// Now Playing の情報（ジャケットを除く）
    static func info(for item: Item) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: item.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: item.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: (item.isAudioOnly ? MPNowPlayingInfoMediaType.audio : .video).rawValue
        ]
        if item.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = item.duration
        }
        if let artist = item.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = item.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        return info
    }

    private func mediaArtwork(for image: CGImage) -> MPMediaItemArtwork {
        if let artwork, artworkImage === image {
            return artwork
        }
        let made = Self.makeArtwork(image)
        artworkImage = image
        artwork = made
        return made
    }

    /// ジャケット。画像を求める処理はメインスレッドの外から呼ばれるので、MainActor に属さないここで作る
    /// （MainActor の中で作ると、呼ばれたときに MainActor の確認で落ちる）
    nonisolated private static func makeArtwork(_ image: CGImage) -> MPMediaItemArtwork {
        let picture = UIImage(cgImage: image)
        return MPMediaItemArtwork(boundsSize: picture.size) { _ in picture }
    }
}
