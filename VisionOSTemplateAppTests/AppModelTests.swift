//
//  AppModelTests.swift
//  VisionOSTemplateAppTests
//

import Testing
@testable import VisionOSTemplateApp

struct AppModelTests {
    /// 起動した直後は Immersive Space が閉じている
    @Test
    func immersiveSpaceIsClosedAtLaunch() {
        #expect(AppModel().immersiveSpaceState == .closed)
    }
}
