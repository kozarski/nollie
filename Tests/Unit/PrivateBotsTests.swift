import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Private is a setting on each bot, not a name: older builds' names are carried over once.
@Suite struct PrivateBotsTests {
    @Test func theSettingDecidesNotTheName() {
        let none = PrivateBots()
        #expect(!none.contains("private"), "a bot named private is not private by its name")
        let marked = none.setting("Scout", private: true)
        #expect(marked.contains("scout") && marked.contains(" SCOUT ") && marked.settled)
        #expect(!marked.setting("scout", private: false).contains("Scout"))
    }

    @Test func olderBuildsNamesAreCarriedOverOnce() {
        let carried = PrivateBots().adoptingLegacyNames(from: ["default", "private", "career"])
        #expect(carried.contains("private") && !carried.contains("career") && carried.settled)
        // Once settled, the names mean nothing: turning Private off sticks.
        let off = carried.setting("private", private: false)
        #expect(!off.adoptingLegacyNames(from: ["private", "moss"]).contains("private"))
        #expect(!PrivateBots(settled: true).adoptingLegacyNames(from: ["moss"]).contains("moss"))
    }
}
