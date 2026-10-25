import Foundation
import Testing
@testable import Nollie

/// LICENSE names Nollie's author, and the third-party notices the app shows match it word for word.
struct AcknowledgementsTests {
    @Test func theNoticesMatchLicense() throws {
        let license = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LICENSE")
        let text = try String(contentsOf: license, encoding: .utf8)
        // LICENSE opens with Nollie's own notice; the credits for parts Nollie installs follow.
        #expect(text.hasPrefix("MIT License\n\nCopyright (c) 2026 Corey Kozarski\n"))
        #expect(text.contains(AcknowledgementsView.cuaPlugin.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(text.contains(AcknowledgementsView.sparkleMIT.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test func everyNoticeHasALicence() {
        #expect(AcknowledgementsView.notices.allSatisfy { !$0.licence.isEmpty && !$0.name.isEmpty })
    }
}
