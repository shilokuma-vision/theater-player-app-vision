//
//  VideoOutputTests.swift
//  TheaterMediaTests
//
//  スクリーン（VideoMaterial）をつなぐたびに、前のスクリーンにつないでいない renderer を渡すか。
//  前のスクリーンにつないだ renderer で次の VideoMaterial を作ると、映す先を足せずに映らなかった
//

@preconcurrency import AVFoundation
import Testing
@testable import TheaterMedia

struct VideoOutputTests {
    /// 最初のスクリーンには、作ったときの renderer をそのまま渡す
    @Test func firstScreenUsesInitialRenderer() {
        let output = VideoOutput()
        let initial = output.renderer
        var given: AVSampleBufferVideoRenderer?
        output.attachScreen { given = $0 }
        #expect(given === initial)
        #expect(output.renderer === initial)
    }

    /// 映画館を開き直してスクリーンをつなぎ直すと、新しい renderer を渡す
    @Test func nextScreenGetsNewRenderer() {
        let output = VideoOutput()
        var first: AVSampleBufferVideoRenderer?
        output.attachScreen { first = $0 }
        output.detachScreen()
        var second: AVSampleBufferVideoRenderer?
        output.attachScreen { second = $0 }
        #expect(second != nil)
        #expect(second !== first)
        #expect(output.renderer === second)
    }

    /// 3D と 2D を切り替えて作り直した renderer は、まだどのスクリーンにもつないでいないので、そのまま渡す
    @Test func rendererReplacedByStereoIsUsedAsIs() {
        let output = VideoOutput()
        output.attachScreen { _ in }
        output.stereo = .sideBySide
        let replaced = output.renderer
        var given: AVSampleBufferVideoRenderer?
        output.attachScreen { given = $0 }
        #expect(given === replaced)
        #expect(output.renderer === replaced)
    }
}
