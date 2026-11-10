import SwiftUI
import NollieCore

/// What a phone linked to a Mac leaves to the Mac. The Mac's door refuses these by design (see
/// `LinkDoorPolicy`): making or editing a schedule, flipping a bot's tools and skills, and its
/// connected apps. The screens say so up front, so nobody taps a control only to be refused.
enum OnYourMac {
    /// True on a phone that reaches its helpers through a linked Mac's door.
    static func applies(_ connection: GatewayConnection?) -> Bool { connection?.linkedMac != nil }

    /// Schedules are made by hand only where the gateway takes them; a linked phone asks Nollie instead.
    static func makesSchedulesByHand(developerMode: Bool, linked: Bool) -> Bool { developerMode && !linked }

    static var changeThese: String { String(localized: "Change these on your Mac.", comment: "A linked iPhone shows a bot's switches but can't flip them") }
    static var editThis: String { String(localized: "Edit this on your Mac.", comment: "A linked iPhone can pause or delete a schedule but not edit it") }
}

/// The one quiet line a linked phone shows in place of a control it can't use.
struct OnYourMacNote: View {
    let words: String

    var body: some View {
        Label(words, systemImage: "macbook")
            .small(.footnote, .secondary)
            .testID("onYourMac.note")
    }
}
