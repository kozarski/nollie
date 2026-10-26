import Testing
@testable import Nollie

struct SettingsCategoryTests {
    @Test func normalSettingsHasOneHomeForEachGroup() {
        #if os(macOS)
        #expect(SettingsCategory.visible(developerMode: false) == [
            .bots, .appearance, .speech, .notifications, .privacy, .signIns, .siri, .connection, .keepAwake, .about
        ])
        #expect(SettingsCategory.visible(developerMode: false, matching: "password") == [.signIns])
        #expect(SettingsCategory.visible(developerMode: false, matching: "sleep") == [.keepAwake])
        #else
        // Saved sign-ins are the Mac's alone: the iPhone never holds a password.
        #expect(SettingsCategory.visible(developerMode: false) == [
            .bots, .appearance, .speech, .notifications, .privacy, .siri, .connection, .about
        ])
        #expect(SettingsCategory.visible(developerMode: false, matching: "password").isEmpty)
        // Keep awake is the Mac's own sleep.
        #expect(SettingsCategory.visible(developerMode: false, matching: "sleep").isEmpty)
        #endif
        #expect(SettingsCategory.visible(developerMode: false, matching: "avatar") == [.bots])
        #expect(SettingsCategory.visible(developerMode: false, matching: "glass") == [.appearance])
    }

    @Test func groupedControlsRemainDiscoverable() {
        for (query, expected) in [("Security", SettingsCategory.privacy), ("Face ID", .privacy),
                                   ("Siri", .siri), ("Spotlight", .siri), ("Models", .connection),
                                   ("Set up", .connection), ("Summaries", .appearance),
                                   ("Voice", .speech), ("Read aloud", .speech), ("Talk", .speech)] {
            #expect(SettingsCategory.visible(developerMode: false, matching: query) == [expected])
        }
    }

    @Test func technicalControlsRequireDeveloperMode() {
        for query in ["Hermes", "Dashboard", "Companion", "Troubleshooting"] {
            #expect(SettingsCategory.visible(developerMode: false, matching: query).isEmpty)
            #expect(SettingsCategory.visible(developerMode: true, matching: query) == [.advanced])
        }
        #expect(SettingsCategory.visible(developerMode: true).last == .advanced)
    }

    @Test func searchAndExistingCategoryIdentifiersRemainStable() {
        #expect(SettingsCategory.visible(developerMode: false, matching: "  SIRI \n") == [.siri])
        #expect(SettingsCategory.privacy.id == "icloud")
        #expect(SettingsCategory.connection.id == "gateways")
        #expect(Set(SettingsCategory.allCases.map(\.id)).count == SettingsCategory.allCases.count)
    }
}
