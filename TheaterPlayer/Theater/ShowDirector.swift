//
//  ShowDirector.swift
//  TheaterPlayer
//
//  上映の進行。再生を「上映」として進め、客電・マスキング（幕）の段階を決める。
//  - 開演の流れ（動画を開いて頭から再生するとき）：開演のブザー → 客電を半分まで落とす → 幕が開く → 客電を消して本編。
//    続きから・シーク・一時停止からの再開では流さない（今どおり客電を落とすだけ）
//

import Foundation
import TheaterMedia

/// 上映の段階。客電の行き先（LightingDirector）と、幕（左右のマスキング）を決める
enum ShowPhase: Equatable {
    /// 開場：何も開いていない・止めている（一時停止を含む）
    case lobby
    /// 開演のブザー（幕を閉じる）
    case buzzer
    /// 客電を半分まで落とす（幕は閉じたまま）
    case dimming
    /// 幕を開ける（客電は半分のまま）
    case opening
    /// 本編（静止画を出しているときも）
    case feature

    /// 幕を閉じておく段階
    var closesCurtain: Bool {
        self == .buzzer || self == .dimming
    }

    /// 再生の状態から、今の段階を決める。ceremony：開演の流れの段階（流していなければ nil）
    static func resolve(ceremony: ShowPhase?, state: PlaybackState, showingStill: Bool) -> ShowPhase {
        if let ceremony {
            return ceremony
        }
        // 静止画を出しているあいだも、上映中と同じく客電を落とす
        if showingStill {
            return .feature
        }
        switch state {
        case .playing, .buffering:
            return .feature
        default:
            return .lobby
        }
    }
}

/// 開演の流れの時刻（流し始めてからの秒）
struct ShowProgram: Equatable {
    /// 客電を半分まで落とし始める（ブザーが鳴り終わるころ）
    var dimming: TimeInterval = 2
    /// 幕を開け始める（客電が半分まで落ちて、少し間をおいたころ）
    var opening: TimeInterval = 5.5
    /// 本編を始め、客電を上映の明るさまで落とす（幕が開き切ったころ）
    var feature: TimeInterval = 8.5
    /// 幕を閉じる秒数（ブザーのあいだに閉じる）
    var curtainClose: TimeInterval = 2
    /// 映画館が描き始めるのを待つ最長の秒数（映画館に入ってすぐは、舞台の読み込みが終わっていない）
    var theaterTimeout: TimeInterval = 20

    static let standard = ShowProgram()

    /// 幕を開ける秒数（開け始めてから本編まで）
    var curtainOpen: TimeInterval {
        feature - opening
    }
}

@MainActor
@Observable
final class ShowDirector {
    /// 開演の流れを流す動画の最短の長さ（秒）。短い動画（スマートフォンで撮った物など）は、すぐに始める
    static let ceremonyMinimumDuration: Double = 5 * 60

    let program: ShowProgram
    /// 開演の流れの段階（流していないときは nil。映画館が描き始めるのを待っているあいだは .lobby）
    private(set) var ceremony: ShowPhase?
    /// 開演の流れを始めた回数（舞台が、開演ごとに 1 回だけブザーを鳴らすため）
    private(set) var performance = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 映画館が最後に描いた時刻
    @ObservationIgnored private var theaterFrame: ContinuousClock.Instant?

    init(program: ShowProgram = .standard) {
        self.program = program
    }

    /// 頭から再生するときに、開演の流れを流すファイルか（動画で、ある程度の長さがある）
    static func wantsCeremony(isAudioOnly: Bool, duration: Double?) -> Bool {
        !isAudioOnly && (duration ?? 0) >= ceremonyMinimumDuration
    }

    // MARK: - 開演の流れ

    /// 開演の流れを流し、終わったら start（本編を始める）を呼ぶ
    func begin(start: @escaping @MainActor () -> Void) {
        cancel()
        performance += 1
        ceremony = .lobby
        task = Task { [weak self] in
            await self?.run(start: start)
        }
    }

    /// 開演の流れをやめる（すぐに始める・一時停止・閉じる）。本編を始めるかは呼ぶ側が決める
    func cancel() {
        task?.cancel()
        task = nil
        ceremony = nil
    }

    /// 映画館が 1 コマ描いた（舞台が毎フレーム呼ぶ）
    func theaterDidRender() {
        theaterFrame = .now
    }

    private func run(start: @MainActor () -> Void) async {
        let clock = ContinuousClock()
        // 映画館に入ってすぐは舞台を読み込んでいるので、描き始めるまで待つ（ブザーや幕を見逃さないように）
        let timeout = clock.now + .seconds(program.theaterTimeout)
        while !isTheaterRendering(at: clock.now), clock.now < timeout {
            guard await wait(until: clock.now + .milliseconds(50)) else {
                return
            }
        }
        let origin = clock.now
        let cues: [(time: TimeInterval, phase: ShowPhase)] = [
            (0, .buzzer),
            (program.dimming, .dimming),
            (program.opening, .opening)
        ]
        for cue in cues {
            guard await wait(until: origin + .seconds(cue.time)) else {
                return
            }
            ceremony = cue.phase
        }
        guard await wait(until: origin + .seconds(program.feature)) else {
            return
        }
        ceremony = nil
        task = nil
        start()
    }

    private func isTheaterRendering(at now: ContinuousClock.Instant) -> Bool {
        theaterFrame.map { now - $0 < .milliseconds(500) } ?? false
    }

    /// deadline まで待つ。取り消されたら false（待ち終えたあとに取り消されたときも）
    private func wait(until deadline: ContinuousClock.Instant) async -> Bool {
        try? await Task.sleep(until: deadline, clock: .continuous)
        return !Task.isCancelled
    }
}
