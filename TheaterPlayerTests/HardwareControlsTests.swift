//
//  HardwareControlsTests.swift
//  TheaterPlayerTests
//
//  キーボード・ゲームコントローラーの割り当て。
//

import GameController
import Testing
@testable import TheaterPlayer

struct HardwareControlsTests {
    @Test func keysControlPlayback() {
        #expect(HardwareControls.command(for: .spacebar) == .togglePlay)
        #expect(HardwareControls.command(for: .leftArrow) == .skip(by: -10))
        #expect(HardwareControls.command(for: .rightArrow) == .skip(by: 10))
        #expect(HardwareControls.command(for: .upArrow) == .changeVolume(by: 0.1))
        #expect(HardwareControls.command(for: .downArrow) == .changeVolume(by: -0.1))
        #expect(HardwareControls.command(for: .keyN) == .nextChapter)
        #expect(HardwareControls.command(for: .keyP) == .previousChapter)
        #expect(HardwareControls.command(for: .returnOrEnter) == .showPanel)
    }

    /// 割り当てていないキー（Esc・文字・数字など）では何もしない
    @Test func otherKeysDoNothing() {
        for key in [GCKeyCode.escape, .keyA, .one, .tab, .deleteOrBackspace] {
            #expect(HardwareControls.command(for: key) == nil)
        }
    }

    @Test func controllerButtonsControlPlayback() {
        #expect(HardwareControls.command(forButton: GCInputButtonA) == .togglePlay)
        #expect(HardwareControls.command(forButton: GCInputButtonB) == .showPanel)
        #expect(HardwareControls.command(forButton: GCInputLeftShoulder) == .previousChapter)
        #expect(HardwareControls.command(forButton: GCInputRightShoulder) == .nextChapter)
        #expect(HardwareControls.command(forButton: GCInputButtonX) == nil)
        #expect(HardwareControls.command(forButton: GCInputButtonMenu) == nil)
    }

    /// 十字キーは、キーボードの矢印と同じ
    @Test func directionPadMatchesArrowKeys() {
        #expect(HardwareControls.command(for: .left) == HardwareControls.command(for: .leftArrow))
        #expect(HardwareControls.command(for: .right) == HardwareControls.command(for: .rightArrow))
        #expect(HardwareControls.command(for: .up) == HardwareControls.command(for: .upArrow))
        #expect(HardwareControls.command(for: .down) == HardwareControls.command(for: .downArrow))
    }
}
