#if os(macOS) && NOLLIE_DIRECT
import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// The Mac's Papertrail filter switch: what it tells Nollie Runtime, and its few words.
@MainActor
struct PapertrailFilterSwitchTests {
    @Test func onAlwaysMeansRefuseToo() throws {
        for on in [true, false] {
            let value = try #require(try JSONSerialization.jsonObject(with: PapertrailFilterModel.switchData(on: on)) as? [String: Any])
            #expect(value["version"] as? Int == 1)
            #expect(value["on"] as? Bool == on)
            #expect(value["refuse"] as? Bool == on)
        }
    }

    @Test func eachStateSaysWhatToDo() {
        #expect(PapertrailFilterWords.line(.off) == nil)
        #expect(PapertrailFilterWords.line(.unavailable) == "Not in this version of Nollie yet.")
        #expect(PapertrailFilterWords.line(.waiting)?.contains("System Settings") == true)
        #expect(PapertrailFilterWords.line(.on)?.contains("stopped") == true)
        for state in [PapertrailFilterModel.State.unavailable, .waiting, .asking, .on, .failed("x")] {
            #expect(!(PapertrailFilterWords.line(state) ?? "").contains("\u{2014}"))
        }
    }

    @Test func thisBuildDoesNotCarryTheFilterUntilThePortalStep() {
        // NOLLIE_NETWORK_FILTER_READY is NO in the project: nothing is embedded, so the switch can't be turned on.
        #expect(!PapertrailFilterModel.embedded)
    }
}
#endif
