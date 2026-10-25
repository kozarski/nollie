import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

typealias RememberedCoordinator = RememberedSignInCoordinator

/// The pure rules: what saving the form does, when a remembered sign-in is used, how often.
@Suite struct RememberedSignInRulesTests {
    // MARK: the gateway form

    struct FormCase: CustomTestStringConvertible, Sendable {
        var mode: AuthMode = .password
        var switchOn: Bool
        var wasOn: Bool
        var typed = true
        var moved = false
        var result: RememberedCoordinator.FormChange
        var testDescription: String { "\(mode) on=\(switchOn) was=\(wasOn) typed=\(typed) moved=\(moved) -> \(result)" }
    }

    static let formCases: [FormCase] = [
        // Switched on with the login entered: stored against the address being saved.
        FormCase(switchOn: true, wasOn: false, result: .remember),
        FormCase(switchOn: true, wasOn: true, result: .remember),
        FormCase(switchOn: true, wasOn: true, moved: true, result: .remember),
        // Left on, nothing typed: what is remembered stays.
        FormCase(switchOn: true, wasOn: true, typed: false, result: .keep),
        // Turned off here.
        FormCase(switchOn: false, wasOn: true, result: .forget),
        FormCase(switchOn: false, wasOn: true, typed: false, result: .forget),
        // Started off and saved off: nothing was asked for, so nothing is forgotten.
        FormCase(switchOn: false, wasOn: false, result: .keep),
        FormCase(switchOn: false, wasOn: false, typed: false, result: .keep),
        // A new address strands the old one.
        FormCase(switchOn: false, wasOn: false, moved: true, result: .forget),
        FormCase(switchOn: true, wasOn: true, typed: false, moved: true, result: .forget),
        // Another way of signing in has no password to use.
        FormCase(mode: .oauth, switchOn: true, wasOn: true, result: .forget),
        FormCase(mode: .sessionToken, switchOn: false, wasOn: false, result: .forget),
    ]

    @Test(arguments: formCases)
    func savingTheFormRemembersKeepsOrForgets(_ scenario: FormCase) {
        let outcome = RememberedCoordinator.formChange(authMode: scenario.mode, switchOn: scenario.switchOn, wasOn: scenario.wasOn,
                                             typed: scenario.typed, moved: scenario.moved)
        #expect(outcome == scenario.result)
    }

    // MARK: when to use it

    struct Situation: CustomTestStringConvertible, Sendable {
        var mode: AuthMode = .password
        var remembered = true
        var hasPasscode = true
        var canPromptNow = true
        var declined = false
        var usedJustNow = false
        var personAsked = false
        var verdict: RememberedCoordinator.Decision
        var testDescription: String { "\(mode) rem=\(remembered) pass=\(hasPasscode) now=\(canPromptNow) declined=\(declined) recent=\(usedJustNow) asked=\(personAsked)" }
    }

    static let situations: [Situation] = [
        Situation(verdict: .useRemembered),
        Situation(mode: .oauth, verdict: .askPerson(.notPasswordSignIn)),
        Situation(mode: .sessionToken, verdict: .askPerson(.notPasswordSignIn)),
        Situation(remembered: false, verdict: .askPerson(.nothingRemembered)),
        Situation(hasPasscode: false, verdict: .askPerson(.noPasscode)),
        // The app is locked or in the background: retry later, not never.
        Situation(canPromptNow: false, verdict: .askPerson(.notNow)),
        // Declined once: no automatic second attempt.
        Situation(declined: true, verdict: .askPerson(.declined)),
        // The Sign In button asks regardless of those three...
        Situation(canPromptNow: false, declined: true, personAsked: true, verdict: .useRemembered),
        Situation(usedJustNow: true, personAsked: true, verdict: .useRemembered),
        // ...but cannot conjure a password that is not there.
        Situation(mode: .oauth, personAsked: true, verdict: .askPerson(.notPasswordSignIn)),
        Situation(remembered: false, personAsked: true, verdict: .askPerson(.nothingRemembered)),
        // Just used, then refused straight away.
        Situation(usedJustNow: true, verdict: .askPerson(.tooSoon)),
        Situation(canPromptNow: false, usedJustNow: true, verdict: .askPerson(.notNow)),
    ]

    @Test(arguments: situations)
    func theDecisionFollowsTheSituation(_ scene: Situation) {
        let verdict = RememberedCoordinator.decide(authMode: scene.mode, remembered: scene.remembered, canAuthenticate: scene.hasPasscode,
                                         canPromptNow: scene.canPromptNow, declined: scene.declined,
                                         usedRecently: scene.usedJustNow, asked: scene.personAsked)
        #expect(verdict == scene.verdict)
    }

    // MARK: the floor on automatic sign-ins

    /// Earlier sign-ins at these offsets (seconds), asked about at `now`.
    static let floors: [(history: [Double], now: Double, allowed: Bool)] = [
        ([], 0, true),
        ([0], 59, false),
        ([0], 60, true),
        ([0, 60, 120], 599, false),
        ([0, 60, 120], 600, true),
        // A clock set back an hour: stamps from the future do not count.
        ([3600, 3660, 3720], 0, true),
    ]

    @Test(arguments: floors)
    func automaticSignInsAreSpacedOut(history: [Double], now: Double, allowed: Bool) {
        let zero = Date(timeIntervalSince1970: 0)
        let stamps = history.map { zero.addingTimeInterval($0) }
        #expect(RememberedCoordinator.allowedByFloor(stamps, now: zero.addingTimeInterval(now)) == allowed)
    }
}
