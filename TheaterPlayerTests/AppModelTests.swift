//
//  AppModelTests.swift
//  TheaterPlayerTests
//

import Testing
@testable import TheaterPlayer

struct AppModelTests {
    /// 起動した直後は Immersive Space が閉じている
    @Test
    func immersiveSpaceIsClosedAtLaunch() {
        #expect(AppModel().immersiveSpaceState == .closed)
    }
}
