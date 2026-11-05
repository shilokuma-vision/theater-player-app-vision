//
//  YouTubeSoundGuard.swift
//  TheaterPlayer
//
//  デバッグ用（デバッグのビルドだけ）：「映画館の音響に通す」のあいだ、ページの元の音を消してよいかと、空間オーディオを鳴らし直すかを決める
//  （1 秒ごとの様子から）。映画館の音響で鳴らせないときに、ページの音まで消えて無音にならないようにする。
//
//  - ページの元の音を消すのは、空間オーディオが描画していて（音源の描画が呼ばれている）、音声を読めているときだけ。
//    一度消したら、鳴らし直しているあいだも消したままにする（消したことで止まったのなら、消したまま鳴るかを確かめる）
//  - 空間オーディオの描画が silentLimit 秒止まったら、鳴らし直す（maxHeals 回まで）。それでも止まったままなら、あきらめて
//    ページの音に戻す（スイッチを入れ直すまで）
//

#if DEBUG
nonisolated struct YouTubeSoundGuard: Equatable {
    /// 描画が止まってから鳴らし直すまで（秒）
    static let silentLimit = 2
    /// 鳴らし直す回数の上限
    static let maxHeals = 3

    enum Action: Equatable {
        case none
        /// 鳴らし直す（attempt は 1 から）
        case heal(attempt: Int)
    }

    /// ページの元の音を消す
    private(set) var mutesOriginal = false
    /// 鳴らし直した回数
    private(set) var heals = 0
    /// 鳴らし直しても描画が止まったままで、あきらめた
    private(set) var gaveUp = false
    /// 描画が止まっている秒数
    private(set) var silentSeconds = 0

    /// 1 秒ごとの様子。rendering：空間オーディオの描画が呼ばれている。decoding：音声を読めている（形式が分かり、問題が無い）
    mutating func update(rendering: Bool, decoding: Bool) -> Action {
        silentSeconds = rendering ? 0 : silentSeconds + 1
        var action = Action.none
        if silentSeconds >= Self.silentLimit, !gaveUp {
            if heals < Self.maxHeals {
                heals += 1
                silentSeconds = 0
                action = .heal(attempt: heals)
            } else {
                gaveUp = true
            }
        }
        mutesOriginal = !gaveUp && decoding && (rendering || mutesOriginal)
        return action
    }
}
#endif
