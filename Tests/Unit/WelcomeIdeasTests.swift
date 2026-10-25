import Testing
@testable import Nollie

struct WelcomeIdeasTests {
    @Test func accessibilityAndVisibilityStopAutomaticChanges() {
        let playback = WelcomeIdeasPlayback()
        #expect(cycles(playback))
        #expect(!cycles(playback, reduceMotion: true))
        #expect(!cycles(playback, voiceOver: true))
        #expect(!cycles(playback, isActive: false))
        #expect(!cycles(playback, sceneIsActive: false))
        #expect(!cycles(playback, automatically: false))
        #expect(!cycles(playback, hovering: true))
        #expect(!cycles(playback, focused: true))
    }

    @Test func manualBrowsingPausesUntilExplicitlyResumed() {
        var playback = WelcomeIdeasPlayback()
        playback.advance(manually: true)
        #expect(playback.page == 1)
        #expect(!cycles(playback))
        playback.advance(manually: true)
        #expect(playback.page == 2)
        #expect(!cycles(playback))
        playback.togglePause()
        #expect(cycles(playback))
        #expect(!cycles(playback, reduceMotion: true))
        #expect(!cycles(playback, voiceOver: true))
    }

    @Test func aFullRotationShowsEveryIdeaAndReturnsToTheFirstSet() {
        var playback = WelcomeIdeasPlayback()
        var seen = Set<String>()
        for _ in 0..<(WelcomeIdeas.pages.count * 3) {
            let ideas = WelcomeIdeas.pages[playback.page]
            #expect(ideas.count == 3)
            seen.formUnion(ideas.map(\.title))
            playback.advance()
        }
        #expect(playback.page == 0)
        #expect(seen.count == 9)
        #expect(cycles(playback))
    }

    @Test func endingHoverOrFocusResumesWithoutLosingThePage() {
        var playback = WelcomeIdeasPlayback()
        playback.advance()
        #expect(!cycles(playback, hovering: true))
        #expect(!cycles(playback, focused: true))
        #expect(playback.page == 1)
        #expect(cycles(playback))
        playback.togglePause()
        #expect(!cycles(playback))
        #expect(playback.page == 1)
    }

    private func cycles(_ playback: WelcomeIdeasPlayback, isActive: Bool = true, sceneIsActive: Bool = true,
                        automatically: Bool = true, reduceMotion: Bool = false, voiceOver: Bool = false,
                        hovering: Bool = false, focused: Bool = false) -> Bool {
        playback.shouldCycle(isActive: isActive, sceneIsActive: sceneIsActive, automatically: automatically,
                             reduceMotion: reduceMotion, voiceOver: voiceOver, hovering: hovering, focused: focused)
    }
}
