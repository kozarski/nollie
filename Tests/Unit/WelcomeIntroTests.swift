import Foundation
import CoreGraphics
import Testing
import NollieCore
@testable import Nollie

struct WelcomeIntroTests {
    @Test func onlyFreshSetupPlaysAutomatically() {
        #expect(plays())
        #expect(!plays(hasConnections: true))
        #expect(!plays(hasSavedProgress: true))
        #expect(!plays(hasSeenIntro: true))
        #expect(!plays(isFixture: true))
    }

    @Test func reducedMotionNeverPlaysEvenForADemo() {
        #expect(!plays(reduceMotion: true))
        #expect(!plays(reduceMotion: true, demoRequested: true))
        #expect(plays(hasConnections: true, hasSavedProgress: true, hasSeenIntro: true, demoRequested: true))
    }

    @Test func wakesNoticesSaysHelloThenHops() {
        let opening = WelcomeIntroTimeline.frame(at: 0)
        let close = WelcomeIntroTimeline.frame(at: 0.9)
        let awake = WelcomeIntroTimeline.frame(at: 1.6)
        let curious = WelcomeIntroTimeline.frame(at: 2.30)
        let hello = WelcomeIntroTimeline.frame(at: 2.80)
        let back = WelcomeIntroTimeline.frame(at: 3.5)
        let finished = WelcomeIntroTimeline.frame(at: WelcomeIntroTimeline.duration)
        #expect(opening.approach == 0 && opening.state == .asleep)
        #expect(close.approach == 1 && close.reveal == 0 && close.state == .asleep)
        #expect(awake.state == .idle)
        #expect(curious.reveal == 1 && curious.state == .listening)
        #expect(hello.settle == 0 && hello.state == .speaking)
        #expect(back.state == .done)
        #expect(finished.settle == 1)
        #expect(WelcomeIntroTimeline.frame(at: .nan) == WelcomeIntroTimeline.frame(at: 0))
    }

    @Test func theHopLandsBeforeTheIntroEnds() throws {
        let hop = try #require(WelcomeIntroTimeline.beats.first { $0.state == .done })
        let length = try #require(CharacterCatalog.shared.state(.done).oneShot)
        #expect(hop.start + length <= WelcomeIntroTimeline.duration)
        #expect(WelcomeIntroTimeline.beats.map(\.start) == WelcomeIntroTimeline.beats.map(\.start).sorted())
    }

    @Test func cameraNeverInflatesTheBodyDuringThePullback() {
        for viewport in viewports {
            let hero = heroFrame(in: viewport)
            var previous = CGFloat.greatestFiniteMagnitude
            for step in 0...500 {
                let frame = WelcomeIntroTimeline.frame(at: Double(step) / 100)
                let camera = WelcomeIntroTimeline.camera(frame: frame, viewport: viewport, hero: hero)
                #expect(camera.scale <= previous + 0.000001 && camera.scale >= 1)
                #expect(camera.center.x.isFinite && camera.center.y.isFinite)
                previous = camera.scale
            }
        }
    }

    @Test func secondEyeEntersOnlyAfterTheNearEyeHasLingered() {
        let eyes = WelcomeIntroTimeline.eyeAnchors
        for viewport in viewports {
            let hero = heroFrame(in: viewport)
            func screenX(time: Double, x: CGFloat) -> CGFloat {
                let camera = WelcomeIntroTimeline.camera(frame: WelcomeIntroTimeline.frame(at: time), viewport: viewport, hero: hero)
                return camera.center.x + camera.scale * (x - 0.5) * hero.width
            }
            for time in [0.9, 1.35] {
                #expect((0...viewport.width).contains(screenX(time: time, x: eyes.near.x)))
                #expect(screenX(time: time, x: eyes.far.x) > viewport.width)
            }
            #expect(screenX(time: 2.07, x: eyes.far.x) < viewport.width)
            #expect(screenX(time: 2.07, x: eyes.near.x) > 0)
            let settled = WelcomeIntroTimeline.camera(frame: WelcomeIntroTimeline.frame(at: WelcomeIntroTimeline.duration), viewport: viewport, hero: hero)
            #expect(settled.scale == 1)
            #expect(abs(settled.center.x - hero.midX) < 0.001)
            #expect(abs(settled.center.y - hero.midY) < 0.001)
        }
    }

    private let viewports = [CGSize(width: 860, height: 740), CGSize(width: 393, height: 852)]

    private func heroFrame(in viewport: CGSize) -> CGRect {
        CGRect(x: (viewport.width - 176) / 2, y: 120, width: 176, height: 176)
    }

    private func plays(hasConnections: Bool = false, hasSavedProgress: Bool = false, hasSeenIntro: Bool = false,
                       reduceMotion: Bool = false, isFixture: Bool = false, demoRequested: Bool = false) -> Bool {
        WelcomeIntroTimeline.shouldPlay(hasConnections: hasConnections, hasSavedProgress: hasSavedProgress,
                                       hasSeenIntro: hasSeenIntro, reduceMotion: reduceMotion,
                                       isFixture: isFixture, demoRequested: demoRequested)
    }
}
