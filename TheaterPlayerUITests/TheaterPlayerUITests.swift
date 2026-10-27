//
//  TheaterPlayerUITests.swift
//  TheaterPlayerUITests
//
//  Created by 村石 拓海 on 2024/05/12.
//

import Darwin
import XCTest

final class TheaterPlayerUITests: XCTestCase {
    override func setUpWithError() throws {
        // UI テストでは失敗した時点で即座に止める
        continueAfterFailure = false
    }

    /// 起動するとライブラリが開き、ファイルを選べる
    @MainActor
    func testLaunchShowsLibrary() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["ファイルを選ぶ"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["映画館に入る"].exists)
    }

    /// 映画館（Immersive Space）に入ると、ライブラリのウィンドウが閉じ、映画館を読み込んでも落ちない
    /// （Info.plist の Scene Manifest と ImmersiveSpace の id が合っているか、モデルの読み込み・座席の組み立てで落ちないか）。
    /// 操作パネル（RealityView の添付）は、visionOS 26.5 の Simulator では XCUITest の問い合わせに出てこない
    /// （debugDescription には出る）ため、「映画館を出る」までは確かめられない
    @MainActor
    func testEnterTheater() throws {
        // GitHub Actions の macOS ランナー（仮想マシン。GPU も仮想）の Simulator では、映画館を描く途中で描画サーバー（backboardd）が落ち、
        // アプリとテストがまとめて止められる。手元の Mac の Simulator では描けるので、仮想マシンのときだけ飛ばす
        // （Simulator の中の GPU の名前はどちらも同じなので、ホストの OS が仮想マシンかで見分ける）
        try XCTSkipIf(Self.isVirtualMachine, "仮想マシンの Simulator では映画館を描けないため飛ばす")

        let app = XCUIApplication()
        app.launch()

        let enter = app.buttons["映画館に入る"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        enter.tap()
        XCTAssertTrue(app.buttons["ファイルを選ぶ"].waitForNonExistence(timeout: 30))

        // 映画館のモデルの読み込みと座席の組み立て（Simulator では数十秒）を待ち、そのあいだに落ちないこと
        sleep(45)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// ホストの OS が仮想マシンの上で動いているか（Simulator のプロセスはホストの OS の上で動く）
    static var isVirtualMachine: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
    }
}
