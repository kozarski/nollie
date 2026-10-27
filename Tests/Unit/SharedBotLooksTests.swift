import Foundation
import Testing
@testable import NollieCore

/// One look per bot on every device: what the gateway keeps wins, a change still on its way is
/// kept, a photo stays where it was picked, and a device offers what the gateway lacks.
@Suite struct SharedBotLooksTests {
    @Test func aHelperAddedOnThePhoneLooksTheSameOnTheMac() {
        // The Mac has never seen Planner, so it would guess a look from the name.
        let shared = ["planner": SharedBotLook(look: "duo", colour: "#336699")]
        let plan = SharedBotLooks.plan(shared: shared, avatars: [:], colours: [:], bots: ["default", "planner"], unsent: [])
        #expect(plan.avatars == ["planner": "look:duo"])
        #expect(plan.colours == ["planner": "#336699"])
        #expect(plan.offers.isEmpty)
        #expect(CharacterLookID.defaultLook(forProfile: "planner") != .duo, "the old guess differed, which was the bug")
    }

    @Test func theGatewaysLookReplacesAnOlderOneHereUnlessThisDeviceHasNotSentItsOwnYet() {
        let shared = ["scout": SharedBotLook(look: "kick"), "mason": SharedBotLook(look: "nite", colour: "#AA0000")]
        let avatars = ["scout": "look:spike", "mason": "look:swell"]
        let colours = ["scout": "#00AA00", "mason": "#0000AA"]
        let plan = SharedBotLooks.plan(shared: shared, avatars: avatars, colours: colours, bots: ["scout", "mason"], unsent: ["mason"])
        // Scout follows the gateway, colour back to its default; Mason keeps the change made here.
        #expect(plan.avatars == ["scout": "look:kick", "mason": "look:swell"])
        #expect(plan.colours == ["mason": "#0000AA"])
        #expect(plan.offers.isEmpty)
    }

    @Test func aPhotoStaysOnItsDeviceAndANewerAppsLookIsLeftAlone() {
        let shared = ["scout": SharedBotLook(look: "kick", colour: "#123456"), "mason": SharedBotLook(look: "rocket")]
        let plan = SharedBotLooks.plan(shared: shared, avatars: ["scout": "photo", "mason": "look:duo"], colours: [:],
                                       bots: ["scout", "mason"], unsent: [])
        #expect(plan.avatars == ["scout": "photo", "mason": "look:duo"])
        #expect(plan.colours == ["scout": "#123456"])
    }

    @Test func aLookOnlyThisDeviceKnowsIsOfferedAndAPhotoIsNot() {
        let avatars = ["planner": "look:duo", "scout": "photo", "gone": "look:kick"]
        let plan = SharedBotLooks.plan(shared: [:], avatars: avatars, colours: ["scout": "#ABCDEF"],
                                       bots: ["planner", "scout", "default"], unsent: [])
        #expect(plan.offers == ["planner": SharedBotLook(look: "duo"), "scout": SharedBotLook(colour: "#ABCDEF")])
        #expect(plan.avatars == avatars && plan.colours == ["scout": "#ABCDEF"], "nothing here changes")
        #expect(SharedBotLook(avatar: "photo", colour: nil) == nil)
        #expect(SharedBotLook(avatar: "studio:old", colour: "") == nil)
    }
}
