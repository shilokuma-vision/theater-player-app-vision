//
//  VisionOSTemplateAppUITests.swift
//  VisionOSTemplateAppUITests
//
//  Created by 村石 拓海 on 2024/05/12.
//

import XCTest

final class VisionOSTemplateAppUITests: XCTestCase {
    override func setUpWithError() throws {
        // UI テストでは失敗した時点で即座に止める
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsContentView() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Hello, world!"].waitForExistence(timeout: 5))
    }

    /// Immersive Space を開いて閉じられることを確認する（Info.plist の Scene Manifest と ImmersiveSpace の id が合っているか）
    @MainActor
    func testToggleImmersiveSpace() throws {
        let app = XCUIApplication()
        app.launch()

        let showButton = app.buttons["Show Immersive Space"]
        XCTAssertTrue(showButton.waitForExistence(timeout: 10))
        showButton.tap()

        let hideButton = app.buttons["Hide Immersive Space"]
        XCTAssertTrue(hideButton.waitForExistence(timeout: 10))
        hideButton.tap()

        XCTAssertTrue(showButton.waitForExistence(timeout: 10))
    }
}
