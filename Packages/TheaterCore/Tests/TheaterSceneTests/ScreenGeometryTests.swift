//
//  ScreenGeometryTests.swift
//  TheaterSceneTests
//

import Foundation
import Testing
@testable import TheaterScene

struct ScreenGeometryTests {
    let spec: ScreenSpec = {
        let json = """
        {"center": [0, 6.85, -27], "radius": 50, "maxWidth": 21, "maxHeight": 10.5, "bottom": 1.6,
         "masking": {"top": "MaskingTop", "bottom": "MaskingBottom", "left": "MaskingLeft", "right": "MaskingRight"},
         "surface": "ScreenSurface", "projector": [0, 10.4, -0.05]}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ScreenSpec.self, from: Data(json.utf8))
    }()

    @Test func scopeUsesTheFullWidthAndMasksTopAndBottom() {
        let frame = ScreenFrame(aspect: 2.39, spec: spec)
        #expect(frame.width == 21)
        #expect(abs(frame.height - 21 / 2.39) < 1e-4)
        let offsets = frame.maskingOffsets(spec: spec)
        #expect(offsets.top < 0)
        #expect(offsets.bottom > 0)
        #expect(offsets.left == 0)
        #expect(offsets.right == 0)
    }

    @Test func sixteenByNineUsesTheFullHeightAndMasksTheSides() {
        let frame = ScreenFrame(aspect: 16.0 / 9.0, spec: spec)
        #expect(frame.height == 10.5)
        #expect(abs(frame.width - 10.5 * 16 / 9) < 1e-4)
        let offsets = frame.maskingOffsets(spec: spec)
        #expect(offsets.left > 0)
        #expect(abs(offsets.left + offsets.right) < 1e-5)
        #expect(offsets.top == 0)
    }

    @Test func screenCurvesTowardTheAudienceAtTheEdges() {
        let center = ScreenMesh.surfacePoint(x: 0, y: 5, spec: spec)
        let edge = ScreenMesh.surfacePoint(x: 10, y: 5, spec: spec)
        #expect(edge.z > center.z)
        #expect(abs(center.z - (-27 + ScreenMesh.offset)) < 1e-4)
        // 端の出っ張り（半径 50 m・幅 21 m の端で約 1.1 m）。字幕などの平らな表示はこれより手前に置く
        #expect(abs(edge.z - (center.z + ScreenMesh.sag(x: 10, spec: spec))) < 1e-4)
        #expect(ScreenMesh.sag(x: 0, spec: spec) == 0)
        #expect(ScreenMesh.sag(x: 10.5, spec: spec) > 1)
    }

    @Test func rotatedVideoTurnsTheTextureCoordinates() {
        #expect(ScreenMesh.rotate(SIMD2(0, 0), .clockwise90) == SIMD2(1, 0))
        #expect(ScreenMesh.rotate(SIMD2(1, 1), .upsideDown) == SIMD2(0, 0))
    }

    /// 幕を閉じる：左のマスキング（Theater.usdz では x が -13.45〜-10.5、原点は 0）を、外側の縁はそのままに中央を越えるまで伸ばす
    @Test func closedCurtainStretchesTheLeftMaskingPastTheCenter() {
        let stretch = HorizontalStretch(inner: -10.5, outer: -13.45, origin: 0, toInner: 0.06, toOuter: -13.45)
        #expect(stretch.scale > 4)
        #expect(abs(stretch.map(-10.5, restOrigin: 0) - 0.06) < 1e-4)
        #expect(abs(stretch.map(-13.45, restOrigin: 0) + 13.45) < 1e-4)
        // 最大の範囲（幅 21 m）の左半分を、すき間なく覆う
        #expect(stretch.map(-10.5, restOrigin: 0) > 0)
        #expect(stretch.map(-13.45, restOrigin: 0) < -spec.maxWidth / 2)
    }

    /// 物の原点が縁から離れていても、縁が行き先に来る（右のマスキング・原点が 12 の物）
    @Test func stretchKeepsTheEdgesWhereverTheOriginIs() {
        let stretch = HorizontalStretch(inner: 10.5, outer: 13.45, origin: 12, toInner: -0.06, toOuter: 13.45)
        #expect(abs(stretch.map(10.5, restOrigin: 12) + 0.06) < 1e-4)
        #expect(abs(stretch.map(13.45, restOrigin: 12) - 13.45) < 1e-4)
        // 作った位置のままなら、倍率 1 で動かない
        let rest = HorizontalStretch(inner: 10.5, outer: 13.45, origin: 12, toInner: 10.5, toOuter: 13.45)
        #expect(abs(rest.scale - 1) < 1e-6)
        #expect(abs(rest.origin - 12) < 1e-5)
    }
}

struct SeatTests {
    @Test func nearbyGroupsUseTheDetailedSeats() {
        #expect(SeatLevelOfDetail.level(distance: 1) == 0)
        #expect(SeatLevelOfDetail.level(distance: 5) == 1)
        #expect(SeatLevelOfDetail.level(distance: 20) == 2)
        let distance = SeatLevelOfDetail.distance(from: SIMD3(0, 1, 0), boxMin: SIMD3(2, 0, -1), boxMax: SIMD3(4, 1, 1))
        #expect(abs(distance - 2) < 1e-5)
    }

    @Test func plateCellsMatchTheExportedAtlas() {
        let plates = PlateCellSpec(columns: 8, rows: 8, vSpan: 0.5, rowLetterOffset: 34)
        let first = plates.cell(0)
        #expect(first.origin == SIMD2(0, 0.4375))
        #expect(first.size == SIMD2(0.125, 0.0625))
        let ninth = plates.cell(9)
        #expect(ninth.origin == SIMD2(0.125, 0.375))
    }
}
