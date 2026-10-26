//
//  TheaterPlayerUITests.swift
//  TheaterPlayerUITests
//
//  Created by 村石 拓海 on 2024/05/12.
//

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

    /// 映画館（Immersive Space）に入り、操作パネルから出られる（Info.plist の Scene Manifest と ImmersiveSpace の id が合っているか）
    @MainActor
    func testEnterAndLeaveTheater() throws {
        let app = XCUIApplication()
        app.launch()

        let enter = app.buttons["映画館に入る"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        enter.tap()

        let leave = app.buttons["leaveTheater"]
        XCTAssertTrue(leave.waitForExistence(timeout: 30))
        leave.tap()

        XCTAssertTrue(app.buttons["ファイルを選ぶ"].waitForExistence(timeout: 15))
    }
}
