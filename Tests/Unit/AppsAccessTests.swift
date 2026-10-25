import Testing
@testable import Nollie
import NollieCore

@MainActor
@Suite struct AppsAccessTests {
    @Test func aBotCardKeepsItsOwnProfileInsteadOfTheGlobalSelection() {
        #expect(BotAccessPresentation.profile(explicit: "work", selected: "default") == "work")
        #expect(BotAccessPresentation.profile(explicit: "default", selected: "work") == "default")
        #expect(BotAccessPresentation.profile(explicit: nil, selected: "work") == "work")
        #expect(BotAccessPresentation.profile(explicit: nil, selected: nil) == "default")
    }

    @Test func aConnectionNeedsAnExplicitSuccessfulProbeBeforeReportingSuccess() {
        let rejected: JSONValue = ["ok": false, "status": "connected", "error": "fixture-secret", "tools": [.object(["name": "read"] )]]
        let text = BotAccessPresentation.connectionTest(rejected)
        #expect(text == "Connection check failed. Check its setup and try again.")
        #expect(!text.contains("fixture-secret"))
        #expect(BotAccessPresentation.connectionTest(["status": "ok"]) == text)
    }

    @Test func theRealProbeToolListIsCountedWithoutExposingToolPayloads() {
        let result: JSONValue = ["ok": true, "tools": [.object(["name": "read"]), .object(["name": "write"] )]]
        #expect(BotAccessPresentation.connectionTest(result) == "Connection checked. 2 tools available.")
        #expect(BotAccessPresentation.connectionTest(["ok": true, "tools": []]) == "Connection checked. 0 tools available.")
        #expect(BotAccessPresentation.connectionTest(["ok": true]) == "Connection checked.")
    }

    @Test func appsAndAccessIsReachableWithAndWithoutAConversation() {
        #expect(ProfileTab.available(withChat: true).contains(.apps))
        #expect(ProfileTab.available(withChat: false).contains(.apps))
        #expect(ProfileTab.apps.title == "Apps")
    }

    @Test func ordinaryToolRowsExplainCapabilitiesWithoutTechnicalNames() {
        let web = ToolsetInfo(name: "web", label: "Web Search & Scraping", description: "web_search, web_extract", enabled: true)
        let terminal = ToolsetInfo(name: "terminal", label: "Terminal & Processes", description: "terminal, process", enabled: true)
        let webCopy = BotAccessPresentation.toolset(web, developerMode: false)
        let terminalCopy = BotAccessPresentation.toolset(terminal, developerMode: false)
        #expect(webCopy.title == "Web research")
        #expect(webCopy.description == "Search the web and read pages.")
        #expect(terminalCopy.title == "Run commands")
        #expect(terminalCopy.description == "Run programs and manage processes on the assistant's computer.")
        #expect(webCopy.description != web.description)
        #expect(terminalCopy.description != terminal.description)
    }

    @Test func developerModeRetainsTheOriginalTechnicalDescription() {
        let web = ToolsetInfo(name: "web", label: "Web Search & Scraping", description: "web_search, web_extract", enabled: true)
        let copy = BotAccessPresentation.toolset(web, developerMode: true)
        #expect(copy.title == web.label)
        #expect(copy.description == "web_search, web_extract")
    }

    @Test func unknownToolsetsKeepTheirNameWithoutLeakingAnUnreviewedDescription() {
        let custom = ToolsetInfo(name: "custom", label: "My service", description: "custom_read, custom_write", enabled: false)
        let ordinary = BotAccessPresentation.toolset(custom, developerMode: false)
        #expect(ordinary.title == "My service")
        #expect(ordinary.description == nil)
        #expect(BotAccessPresentation.toolset(custom, developerMode: true).description == custom.description)
        #expect(BotAccessPresentation.toolset(ToolsetInfo(name: "custom", enabled: true), developerMode: false).title == "custom")
    }

    @Test func potentiallyChangingActionsStayVisibleWithoutOpeningMoreCapabilities() {
        let names = ["web", "file", "browser", "terminal", "computer_use", "code_execution", "code", "memory", "cronjob", "vision", "custom"]
        let tools = names.map { ToolsetInfo(name: $0, enabled: $0 != "custom") }
        let groups = BotAccessPresentation.grouped(tools)
        #expect(groups.everyday.map(\.name) == ["web", "memory", "cronjob"])
        #expect(groups.actions.map(\.name) == ["file", "browser", "terminal", "computer_use", "code_execution", "code"])
        #expect(groups.more.map(\.name) == ["vision", "custom"])
        let all = groups.everyday + groups.actions + groups.more
        #expect(all.count == tools.count)
        #expect(Set(all) == Set(tools))
        #expect(groups.more.filter(\.enabled).count == 1)
    }
}
