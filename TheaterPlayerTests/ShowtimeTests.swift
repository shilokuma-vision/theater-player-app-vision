//
//  ShowtimeTests.swift
//  TheaterPlayerTests
//
//  上映の進行：客電の段階・上映の段階の決め方・開演の流れ・エンドロールの見つけ方・開演のブザー。
//

import Foundation
import Testing
import TheaterMedia
@testable import TheaterPlayer

@MainActor
struct ShowLightingTests {
    func preferences() -> Preferences {
        Preferences(defaults: UserDefaults(suiteName: "ShowLightingTests.\(UUID().uuidString)") ?? .standard)
    }

    /// 開演の流れ：ブザーのあいだは開場のまま、1 段目で半分まで落とし、幕が開き切るまで半分のまま、本編で上映中の明るさ
    @Test func ceremonyDimsInTwoSteps() {
        let preferences = preferences()
        let house = preferences.houseLevel
        let show = preferences.showLevel
        #expect(LightingDirector.cue(for: .buzzer, preferences: preferences).level == house)
        let half = LightingDirector.cue(for: .dimming, preferences: preferences).level
        #expect(abs(half - (house + show) / 2) < 1e-9)
        #expect(LightingDirector.cue(for: .opening, preferences: preferences).level == half)
        #expect(LightingDirector.cue(for: .feature, preferences: preferences).level == show)
    }

    /// 毎フレーム進めると、半分で止まり、本編で上映中の明るさまで落ちる（それぞれ約 3 秒）
    @Test func houseLightsStopHalfwayBeforeTheFeature() {
        let preferences = preferences()
        let director = LightingDirector(initialHouse: preferences.houseLevel)
        let half = LightingDirector.cue(for: .dimming, preferences: preferences).level
        for _ in 0..<35 {
            _ = director.step(deltaTime: 0.1, phase: .dimming, hasVideo: false, preferences: preferences, light: nil)
        }
        #expect(abs(director.house - half) < 1e-9)
        for _ in 0..<20 {
            _ = director.step(deltaTime: 0.1, phase: .opening, hasVideo: false, preferences: preferences, light: nil)
        }
        #expect(abs(director.house - half) < 1e-9)
        for _ in 0..<35 {
            _ = director.step(deltaTime: 0.1, phase: .feature, hasVideo: true, preferences: preferences, light: nil)
        }
        #expect(director.house == preferences.showLevel)
    }

    /// エンドロール：上映中より少しだけ明るく（半分より暗く）、ゆっくり上げる。終映は開場の明るさへ、ふだんよりゆっくり戻す
    @Test func creditsRaiseTheLightsALittleAndSlowly() {
        let preferences = preferences()
        let credits = LightingDirector.cue(for: .credits, preferences: preferences)
        #expect(credits.level > preferences.showLevel)
        #expect(credits.level < LightingDirector.cue(for: .dimming, preferences: preferences).level)
        let director = LightingDirector(initialHouse: preferences.showLevel)
        _ = director.step(deltaTime: 1, phase: .credits, hasVideo: true, preferences: preferences, light: nil)
        #expect(director.house > preferences.showLevel)
        #expect(director.house < credits.level)
        let ended = LightingDirector.cue(for: .ended, preferences: preferences)
        #expect(ended.level == preferences.houseLevel)
        #expect(ended.rise > LightingDirector.cue(for: .lobby, preferences: preferences).rise)
    }

    /// 「再生すると暗くする」を切にしていれば、どの段階でも開場の明るさのまま
    @Test func autoDimOffKeepsTheHouseLightsOn() {
        let preferences = preferences()
        preferences.autoDim = false
        let phases: [ShowPhase] = [.lobby, .buzzer, .dimming, .opening, .feature, .credits, .ended]
        for phase in phases {
            #expect(LightingDirector.cue(for: phase, preferences: preferences).level == preferences.houseLevel)
        }
    }

    /// 上映中の明るさを開場より明るくしていても、エンドロールで暗くはしない
    @Test func creditsNeverDimBelowTheShowLevel() {
        let preferences = preferences()
        preferences.houseLevel = 0
        preferences.showLevel = 0.5
        #expect(LightingDirector.cue(for: .credits, preferences: preferences).level == 0.5)
    }
}

@MainActor
struct ShowPhaseTests {
    func resolve(
        ceremony: ShowPhase? = nil,
        state: PlaybackState,
        still: Bool = false,
        credits: Bool = false,
        showtime: Bool = true
    ) -> ShowPhase {
        ShowPhase.resolve(ceremony: ceremony, state: state, showingStill: still, inCredits: credits, showtime: showtime)
    }

    @Test func ceremonyComesFirst() {
        #expect(resolve(ceremony: .buzzer, state: .paused) == .buzzer)
        #expect(resolve(ceremony: .opening, state: .paused) == .opening)
    }

    /// 一時停止すると開場の明るさに戻り、再開すると本編に戻る（開演の流れは繰り返さない）
    @Test func pauseReturnsToTheLobby() {
        #expect(resolve(state: .playing) == .feature)
        #expect(resolve(state: .buffering) == .feature)
        #expect(resolve(state: .paused) == .lobby)
        #expect(resolve(state: .idle) == .lobby)
    }

    @Test func creditsAndEndingOnlyForTheShowtime() {
        #expect(resolve(state: .playing, credits: true) == .credits)
        #expect(resolve(state: .playing, credits: true, showtime: false) == .feature)
        #expect(resolve(state: .ended) == .ended)
        #expect(resolve(state: .ended, showtime: false) == .lobby)
        // 一時停止しているあいだは、エンドロールでも開場の明るさ
        #expect(resolve(state: .paused, credits: true) == .lobby)
    }

    @Test func stillPicturesDimLikeTheFeature() {
        #expect(resolve(state: .idle, still: true) == .feature)
    }

    @Test func curtainClosesOnlyBeforeItOpens() {
        #expect(ShowPhase.buzzer.closesCurtain)
        #expect(ShowPhase.dimming.closesCurtain)
        #expect(!ShowPhase.opening.closesCurtain)
        #expect(!ShowPhase.feature.closesCurtain)
    }
}

@MainActor
struct ShowDirectorTests {
    /// 試験用の短い開演の流れ
    let quick = ShowProgram(dimming: 0.02, opening: 0.04, feature: 0.06, curtainClose: 0, theaterTimeout: 0)

    /// 動画で、ある程度の長さがあるときだけ流す（音楽・短い動画・長さが分からない物は流さない）
    @Test func ceremonyIsForFeatureLengthVideos() {
        #expect(ShowDirector.wantsCeremony(isAudioOnly: false, duration: 7_200))
        #expect(ShowDirector.wantsCeremony(isAudioOnly: false, duration: 5 * 60))
        #expect(!ShowDirector.wantsCeremony(isAudioOnly: false, duration: 90))
        #expect(!ShowDirector.wantsCeremony(isAudioOnly: true, duration: 7_200))
        #expect(!ShowDirector.wantsCeremony(isAudioOnly: false, duration: nil))
    }

    /// ブザー → 半分 → 幕が開く の順に進み、最後に 1 回だけ本編を始める
    @Test func ceremonyRunsInOrderAndStartsTheFeatureOnce() async {
        let director = ShowDirector(program: quick)
        var started = 0
        var seen: [ShowPhase] = []
        director.begin { started += 1 }
        #expect(director.ceremony == .lobby)
        #expect(director.performance == 1)
        for _ in 0..<200 where started == 0 {
            if let phase = director.ceremony, seen.last != phase {
                seen.append(phase)
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(started == 1)
        #expect(director.ceremony == nil)
        // 短い間隔なので取りこぼす段階もあるが、順番は逆にならない
        let order: [ShowPhase] = [.lobby, .buzzer, .dimming, .opening]
        let indices = seen.compactMap { order.firstIndex(of: $0) }
        #expect(indices == indices.sorted())
    }

    /// 途中でやめたら（すぐに始める・止める・閉じる）、本編は始めない
    @Test func cancelledCeremonyDoesNotStart() async throws {
        let director = ShowDirector(program: quick)
        var started = false
        director.begin { started = true }
        director.cancel()
        #expect(director.ceremony == nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!started)
    }

    /// 映画館が描き始めるまでは、ブザーを鳴らさずに待つ
    @Test func ceremonyWaitsForTheTheater() async throws {
        var program = quick
        program.theaterTimeout = 5
        let director = ShowDirector(program: program)
        var started = false
        director.begin { started = true }
        try await Task.sleep(for: .milliseconds(150))
        #expect(director.ceremony == .lobby)
        #expect(!started)
        for _ in 0..<200 where !started {
            director.theaterDidRender()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(started)
        director.cancel()
    }

    /// チャプターが無ければ、終わり近くの暗い画面で見つける。見つけた時刻より前へシークして戻れば本編。閉じたら忘れる
    @Test func creditsFromTheDarkScreen() {
        let director = ShowDirector(program: quick)
        director.prepare(duration: 7_200, chapters: [], isVideo: true)
        #expect(director.creditsStart == nil)
        var dark = ScreenLight.black
        dark.center = SIMD3(repeating: 0.04)
        for step in 0...310 {
            director.observe(time: 6_700 + Double(step) / 10, light: dark)
        }
        #expect(director.creditsStart == 6_700)
        #expect(director.isCredits(at: 6_800))
        #expect(!director.isCredits(at: 6_600))
        director.reset()
        #expect(director.creditsStart == nil)
    }

    /// 音楽では探さない
    @Test func noCreditsForMusic() {
        let director = ShowDirector(program: quick)
        director.prepare(duration: 7_200, chapters: [], isVideo: false)
        for step in 0...310 {
            director.observe(time: 6_700 + Double(step) / 10, light: .black)
        }
        #expect(director.creditsStart == nil)
    }
}

@MainActor
struct CreditsFinderTests {
    typealias Mark = CreditsFinder.Mark

    // MARK: チャプター

    @Test func findsCreditsChaptersByName() {
        let marks = [Mark(start: 0, title: "Opening"), Mark(start: 3_000, title: "The Battle"), Mark(start: 6_900, title: "End Credits")]
        #expect(CreditsFinder.chapterStart(marks, duration: 7_200) == 6_900)
        let japanese = [Mark(start: 0, title: "本編"), Mark(start: 6_600, title: "エンドロール")]
        #expect(CreditsFinder.chapterStart(japanese, duration: 7_200) == 6_600)
        let upper = [Mark(start: 0, title: nil), Mark(start: 1_300, title: "CREDITS")]
        #expect(CreditsFinder.chapterStart(upper, duration: 1_440) == 1_300)
    }

    /// 始まりのクレジット・前半のチャプター・名前の無いチャプターは使わない（本編中に明るくしない）
    @Test func ignoresOpeningAndEarlyChapters() {
        #expect(CreditsFinder.chapterStart([Mark(start: 6_800, title: "Opening Credits")], duration: 7_200) == nil)
        #expect(CreditsFinder.chapterStart([Mark(start: 60, title: "Credits")], duration: 7_200) == nil)
        let numbered = (0..<12).map { Mark(start: Double($0) * 600, title: "Chapter \($0 + 1)") }
        #expect(CreditsFinder.chapterStart(numbered, duration: 7_200) == nil)
        #expect(CreditsFinder.chapterStart([Mark](), duration: 7_200) == nil)
    }

    /// エンドロールのあとの場面（Post-Credits Scene）より、エンドロールの始まりを選ぶ。長さが分からなければ、最後のチャプターで比べる
    @Test func picksTheEarliestCreditsChapter() {
        let marks = [
            Mark(start: 0, title: "Start"),
            Mark(start: 6_700, title: "End Credits"),
            Mark(start: 7_100, title: "Post-Credits Scene")
        ]
        #expect(CreditsFinder.chapterStart(marks, duration: 7_200) == 6_700)
        #expect(CreditsFinder.chapterStart(marks, duration: nil) == 6_700)
    }

    // MARK: 暗い画面

    func light(_ value: SIMD3<Float>) -> ScreenLight {
        var light = ScreenLight.black
        light.left = value * 0.4
        light.center = value
        light.right = value * 0.4
        return light
    }

    /// 白い文字の黒地（中央に少しだけ明るさがある）
    var creditsLight: ScreenLight {
        light(SIMD3(repeating: 0.05))
    }

    /// time から seconds 秒、0.1 秒ごとに light を渡す。見つかった始まりを返す
    func feed(_ finder: inout CreditsFinder, from time: Double, seconds: Double, light: ScreenLight) -> Double? {
        var found: Double?
        for step in 0...Int(seconds * 10) {
            if let start = finder.observe(time: time + Double(step) / 10, light: light) {
                found = found ?? start
            }
        }
        return found
    }

    /// 長い作品の終わり近くで、暗い画面が 30 秒続いたら、暗くなった時刻をエンドロールの始まりとする
    @Test func darkNeutralScreenNearTheEndIsCredits() {
        var finder = CreditsFinder(duration: 7_200)
        #expect(feed(&finder, from: 6_700, seconds: 20, light: creditsLight) == nil)
        #expect(feed(&finder, from: 6_720.1, seconds: 15, light: creditsLight) == 6_700)
    }

    /// 終わりから遠い所・短い作品・長さが分からない物では、暗い画面でも明るくしない
    @Test func darkScreensElsewhereAreNotCredits() {
        var early = CreditsFinder(duration: 7_200)
        #expect(feed(&early, from: 3_000, seconds: 60, light: creditsLight) == nil)
        var short = CreditsFinder(duration: 45 * 60)
        #expect(feed(&short, from: 44 * 60, seconds: 50, light: creditsLight) == nil)
        var unknown = CreditsFinder(duration: nil)
        #expect(feed(&unknown, from: 6_700, seconds: 60, light: creditsLight) == nil)
    }

    /// 色の付いた暗い場面（夜の青など）・明るい場面は、エンドロールにしない
    @Test func coloredOrBrightScenesAreNotCredits() {
        var night = CreditsFinder(duration: 7_200)
        #expect(feed(&night, from: 6_700, seconds: 60, light: light(SIMD3(0.005, 0.015, 0.04))) == nil)
        var bright = CreditsFinder(duration: 7_200)
        #expect(feed(&bright, from: 6_700, seconds: 60, light: light(SIMD3(repeating: 0.3))) == nil)
        #expect(CreditsFinder.looksLikeCredits(.black))
    }

    /// 明るいコマが挟まる・シークで飛ぶと、数え直す
    @Test func interruptionsRestartTheCount() {
        var finder = CreditsFinder(duration: 7_200)
        #expect(feed(&finder, from: 6_700, seconds: 25, light: creditsLight) == nil)
        #expect(finder.observe(time: 6_725.1, light: light(SIMD3(repeating: 0.4))) == nil)
        #expect(feed(&finder, from: 6_725.2, seconds: 25, light: creditsLight) == nil)
        var seeking = CreditsFinder(duration: 7_200)
        #expect(feed(&seeking, from: 6_700, seconds: 20, light: creditsLight) == nil)
        #expect(feed(&seeking, from: 6_900, seconds: 20, light: creditsLight) == nil)
    }
}

struct BuzzerSoundTests {
    /// 長さどおりで、振幅は上限を超えず、鳴り始めと鳴り終わりは静か（ぶつっと鳴らない）
    @Test @MainActor func samplesFadeInAndOut() {
        let samples = BuzzerSound.samples()
        #expect(samples.count == Int(BuzzerSound.length * BuzzerSound.sampleRate))
        let peak = samples.map(abs).max() ?? 0
        #expect(peak <= BuzzerSound.peak + 1e-4)
        #expect(peak > BuzzerSound.peak * 0.7)
        #expect(abs(samples[0]) < 0.01)
        #expect(abs(samples[samples.count - 1]) < 0.01)
    }

    /// 音量の設定に合わせて強さを変え、0 なら鳴らさない
    @Test @MainActor func gainFollowsTheVolume() throws {
        #expect(BuzzerSound.gain(volume: 0) == nil)
        #expect(BuzzerSound.gain(volume: 1) == BuzzerSound.baseGain)
        let half = try #require(BuzzerSound.gain(volume: 0.5))
        #expect(abs(half - (BuzzerSound.baseGain - 6.02)) < 0.01)
    }
}

struct ShowtimePreferencesTests {
    /// 上映の演出は既定で入。切にしたら覚える
    @Test @MainActor func showtimeIsOnByDefaultAndSaved() throws {
        let suite = "ShowtimePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.showtime)
        preferences.showtime = false
        #expect(!Preferences(defaults: defaults).showtime)
    }
}
