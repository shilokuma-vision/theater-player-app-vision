//
//  HardwareControls.swift
//  TheaterPlayer
//
//  Bluetooth のキーボードとゲームコントローラーで、再生を操作する（GameController）。
//  GCKeyboard は、パネルにフォーカスが無くてもキーを受けるので、パネルを出さずに操作できる。
//  押したときだけ動かす（離したとき・押し続けたあいだは動かさない）。閉じる・消すのような取り消せない操作は割り当てない。
//

import GameController
import UIKit

final class HardwareControls {
    /// 受けた操作の渡し先（AppModel.perform(_:)）
    private var perform: ((PlayerCommand) -> Void)?
    private var observers: [NSObjectProtocol] = []

    /// 音量の 1 回の上げ下げ（等倍の 10 分の 1）
    nonisolated static let volumeStep = 0.1
    /// ← → ・十字キーの左右で動く秒数
    nonisolated static let skipInterval: Double = 10

    /// キーボード・コントローラーからの操作を受け始める（AppModel が 1 回だけ呼ぶ）。あとからつないだ機器も受ける
    func connect(_ perform: @escaping (PlayerCommand) -> Void) {
        self.perform = perform
        // つないだ知らせの機器（通知の object）は MainActor へ渡せない（Sendable でない）ので、
        // 知らせが来たら、つながっている機器を MainActor で見直す（同じ機器に付け直しても、受ける処理が入れ替わるだけ）
        for name in [Notification.Name.GCKeyboardDidConnect, .GCControllerDidConnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.bindConnectedDevices()
                }
            })
        }
        bindConnectedDevices()
    }

    private func bindConnectedDevices() {
        if let keyboard = GCKeyboard.coalesced {
            bind(keyboard)
        }
        GCController.controllers().forEach(bind)
    }

    // MARK: - 割り当て

    /// キーの割り当て。スペース＝再生・一時停止、← →＝10 秒戻る・進む、↑ ↓＝音量、N・P＝次・前のチャプター、Return＝パネルを出す
    nonisolated static func command(for key: GCKeyCode) -> PlayerCommand? {
        switch key {
        case .spacebar:
            .togglePlay
        case .leftArrow:
            .skip(by: -skipInterval)
        case .rightArrow:
            .skip(by: skipInterval)
        case .upArrow:
            .changeVolume(by: volumeStep)
        case .downArrow:
            .changeVolume(by: -volumeStep)
        case .keyN:
            .nextChapter
        case .keyP:
            .previousChapter
        case .returnOrEnter:
            .showPanel
        default:
            nil
        }
    }

    /// コントローラーのボタンの割り当て（GCInputButtonA などの名前）。A＝再生・一時停止、B＝パネルを出す、L1・R1＝前・次のチャプター
    nonisolated static func command(forButton name: String) -> PlayerCommand? {
        switch name {
        case GCInputButtonA:
            .togglePlay
        case GCInputButtonB:
            .showPanel
        case GCInputLeftShoulder:
            .previousChapter
        case GCInputRightShoulder:
            .nextChapter
        default:
            nil
        }
    }

    /// 十字キーの向き
    nonisolated enum Direction: CaseIterable {
        case left, right, up, down
    }

    /// 十字キーの割り当て。左右＝10 秒戻る・進む、上下＝音量（キーボードの矢印と同じ）
    nonisolated static func command(for direction: Direction) -> PlayerCommand {
        switch direction {
        case .left:
            .skip(by: -skipInterval)
        case .right:
            .skip(by: skipInterval)
        case .up:
            .changeVolume(by: volumeStep)
        case .down:
            .changeVolume(by: -volumeStep)
        }
    }

    // MARK: - 機器につなぐ

    private func bind(_ keyboard: GCKeyboard) {
        guard let input = keyboard.keyboardInput else {
            return
        }
        // 受ける処理はどの actor にも属さないようにする（GameController がどのスレッドから呼んでも落ちないように）
        input.keyChangedHandler = { @Sendable [weak self] keyboard, _, code, pressed in
            // ⌘・⌃・⌥ を押しながらのキーは、システムやほかのショートカットのものなので受けない
            let modifiers: [GCKeyCode] = [.leftGUI, .rightGUI, .leftControl, .rightControl, .leftAlt, .rightAlt]
            guard pressed, !modifiers.contains(where: { keyboard.button(forKeyCode: $0)?.isPressed == true }),
                  let command = Self.command(for: code) else {
                return
            }
            self?.send(command)
        }
    }

    private func bind(_ controller: GCController) {
        let profile = controller.physicalInputProfile
        for name in [GCInputButtonA, GCInputButtonB, GCInputLeftShoulder, GCInputRightShoulder] {
            guard let button = profile.buttons[name], let command = Self.command(forButton: name) else {
                continue
            }
            handlePress(of: button, command)
        }
        if let pad = profile.dpads[GCInputDirectionPad] {
            let buttons: [(GCControllerButtonInput, Direction)] = [(pad.left, .left), (pad.right, .right), (pad.up, .up), (pad.down, .down)]
            for (button, direction) in buttons {
                handlePress(of: button, Self.command(for: direction))
            }
        }
    }

    private func handlePress(of button: GCControllerButtonInput, _ command: PlayerCommand) {
        button.pressedChangedHandler = { @Sendable [weak self] _, _, pressed in
            if pressed {
                self?.send(command)
            }
        }
    }

    nonisolated private func send(_ command: PlayerCommand) {
        Task { @MainActor [weak self] in
            // 文字を入力しているあいだ（検索の欄など）は、スペース・矢印を文字の入力に任せる
            guard !TextInputFocus.isEditing else {
                return
            }
            self?.perform?(command)
        }
    }
}

/// 文字を入力している（入力の欄がファーストレスポンダー）か。
/// GCKeyboard は入力の欄があってもキーを受けるので、入力中にスペースで一時停止しないよう、ここで見分ける
enum TextInputFocus {
    private static weak var found: UIResponder?

    static var isEditing: Bool {
        found = nil
        // 宛先を指定しないアクションは、ファーストレスポンダーに届く
        UIApplication.shared.sendAction(#selector(UIResponder.theaterReportFirstResponder), to: nil, from: nil, for: nil)
        defer { found = nil }
        return found is UITextInput
    }

    fileprivate static func report(_ responder: UIResponder) {
        found = responder
    }
}

extension UIResponder {
    @objc fileprivate func theaterReportFirstResponder() {
        TextInputFocus.report(self)
    }
}
