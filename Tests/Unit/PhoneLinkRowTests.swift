#if os(macOS)
import Foundation
import Testing
@testable import Nollie

/// Settings' iPhone & iPad row on the Mac: what it says beside its name, and when it shows.
@MainActor
struct PhoneLinkRowTests {
    private func device(_ name: String, person: String? = nil) -> NollieLinkIPCDevice {
        NollieLinkIPCDevice(id: UUID(), name: name, linkedAt: Date(), lastActive: nil, person: person)
    }

    @Test func itSaysWhichDeviceIsLinkedOrNotLinked() {
        #expect(PhoneLinkRow.value(nil) == nil, "Nothing claimed before Nollie Runtime answers")
        #expect(PhoneLinkRow.value([]) == "Not linked")
        #expect(PhoneLinkRow.value([device("Sam's iPhone")]) == "Sam's iPhone")
        #expect(PhoneLinkRow.value([device("Sam's iPhone"), device("Sam's iPad")]) == "2 linked")
        let own = PhoneLinkRow.own([device("Sam's iPhone"), device("Alex's iPhone", person: "Alex")])
        #expect(own.map(\.name) == ["Sam's iPhone"], "A shared helper's phone at home is not the owner's")
    }

    @Test func itShowsOnlyForNolliesOwnAssistantAndAnswersSearch() {
        #expect(PhoneLinkRow.shows(available: true, search: ""))
        #expect(!PhoneLinkRow.shows(available: false, search: ""), "Another Hermes has no door for a phone")
        #expect(PhoneLinkRow.shows(available: true, search: "ipad"))
        #expect(PhoneLinkRow.shows(available: true, search: "pair"))
        #expect(!PhoneLinkRow.shows(available: true, search: "keychain"))
    }
}
#endif
