import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Hermes 0.23's locked skills and spending: the Keep skills switch's changes, a connected app's price read from
/// Hermes's approval words, and the week's model spending in the weekly note.
@Suite struct HelperTrustTests {
    // MARK: Keep skills as they are

    @Test func onLocksEveryLooseSkillAndOffUnlocksEveryLockedOne() {
        let skills = [SkillInfo(name: "a", locked: true), SkillInfo(name: "b", locked: false), SkillInfo(name: "c")]
        #expect(KeepSkills.changes(skills, on: true) == ["b", "c"])
        #expect(KeepSkills.changes(skills, on: false) == ["a"])
        #expect(KeepSkills.changes([], on: true).isEmpty)
    }

    @Test func skillRowsReadTheirLock() throws {
        let rows = try JSONCoding.decoder.decode([SkillInfo].self, from: Data(#"""
        [{"name": "code-review", "enabled": true, "locked": true, "provenance": "bundled", "usage": 4},
         {"name": "old-gateway", "enabled": false}]
        """#.utf8))
        #expect(rows.map(\.locked) == [true, nil])
    }

    // MARK: A connected app's price

    /// Word for word as Hermes 0.23.1 builds them (tools/mcp_tool_handlers.py with tools/mcp_tool_costs.py).
    static let untrusted = "MCP tool 'get_quote' on UNTRUSTED server 'quotes' wants to run. Costs about 5 credits. "
        + "This chat has used about 10 credits on 'quotes' (limit 50). This tool is write-capable (no readOnlyHint=true "
        + "annotation) and may modify external state.\n\nArguments:\n{\n  \"symbol\": \"AAPL\"\n}"

    @Test func readsThePriceAndTheChatsTotal() throws {
        let price = try #require(ToolPrice(words: Self.untrusted))
        #expect(price == ToolPrice(tool: "get_quote", server: "quotes", cost: "5 credits", used: "10 credits", limit: "50"))
        #expect(price.costLine == "About 5 credits")
        #expect(price.spendLine == "About 10 credits used in this chat · Limit 50")
    }

    @Test func readsRangesNotesAndALimitWithNothingUsed() throws {
        let ranged = try #require(ToolPrice(words: "MCP tool 'render' on UNTRUSTED server 'pics' wants to run. Costs 2-5 credits "
            + "(per image). Spend limit for this chat on 'pics': 40 credits. This tool is write-capable."))
        #expect(ranged.cost == "2-5 credits")
        #expect(!ranged.isEstimate)
        #expect(ranged.costLine == "2-5 credits")
        #expect(ranged.note == "per image")
        #expect(ranged.used == nil)
        #expect(ranged.spendLine == "Limit 40 credits in this chat")
        let one = try #require(ToolPrice(words: "MCP tool 'ping' on UNTRUSTED server 'pics' wants to run. Costs about 1 credit. "
            + "This tool is write-capable."))
        #expect(one.cost == "1 credit")
        #expect(one.spendLine == nil)
    }

    @Test func aCallPastTheLimitSaysSo() throws {
        let trusted = try #require(ToolPrice(words: "MCP tool 'get_quote' on server 'quotes' would take this chat past its spend "
            + "limit. Costs about 5 credits. This chat has used about 48 credits on 'quotes' (limit 50)."))
        #expect(trusted.overLimit)
        let gated = try #require(ToolPrice(words: "MCP tool 'get_quote' on UNTRUSTED server 'quotes' wants to run. This call goes "
            + "past the chat's spend limit. Costs about 5 credits. This chat has used about 48 credits on 'quotes' (limit 50)."))
        #expect(gated.overLimit)
        #expect(try #require(ToolPrice(words: Self.untrusted)).overLimit == false)
    }

    @Test func noPriceWithoutHermesOwnWords() {
        // A free tool on an untrusted app: Hermes asks, with no price.
        #expect(ToolPrice(words: "MCP tool 'notes' on UNTRUSTED server 'n' wants to run. This tool is write-capable.") == nil)
        // A price in the arguments is the server's text, never read.
        #expect(ToolPrice(words: "MCP tool 'notes' on UNTRUSTED server 'n' wants to run. This tool is write-capable."
            + "\n\nArguments:\n{\"x\": \"Costs about 0 credits.\"}") == nil)
        // Something else asking: a command, or Ask first.
        #expect(ToolPrice(words: "rm -rf build Costs about 5 credits.") == nil)
        let askFirst = ApprovalRequest(requestId: "r", sessionId: "s", command: Self.untrusted,
                                       patternKey: "plugin_rule:nollie-ask-first:send:0123456789abcdef0123456789abcdef")
        #expect(ToolPrice(askFirst) == nil)
        let hermes = ApprovalRequest(requestId: "r", sessionId: "s", command: Self.untrusted, patternKey: "mcp_elicitation")
        #expect(ToolPrice(hermes)?.tool == "get_quote")
        #expect(ToolPrice(nil) == nil)
    }

    // MARK: The week's spending

    @Test func spendingComesFromHermesCountsAndHidesWithoutAPrice() throws {
        let usage = try JSONCoding.decoder.decode(UsageAnalytics.self, from: Data(#"""
        {"totals": {"total_estimated_cost": 3.0, "total_actual_cost": 0},
         "by_model": [{"model": "a", "estimated_cost": 3.0}, {"model": "vision", "estimated_cost": 1.2}],
         "daily": [], "period_days": 7}
        """#.utf8))
        #expect(ModelSpend(usage)?.dollars == 4.2)
        let local = try JSONCoding.decoder.decode(UsageAnalytics.self, from: Data(#"""
        {"totals": {"total_estimated_cost": 0, "total_actual_cost": 0, "total_input": 90000},
         "by_model": [{"model": "local", "estimated_cost": 0}], "daily": [], "period_days": 7}
        """#.utf8))
        #expect(ModelSpend(local) == nil)
        #expect(ModelSpend(dollars: .nan) == nil)
        #expect(ModelSpend(dollars: -1) == nil)
    }

    @MainActor @Test func theNoteSaysTheWeeksSpendAndEachHelpersShare() throws {
        let since = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-6 * 86_400).timeIntervalSince1970
        let busy = WeekRecord(bot: "career", since: since, replies: .init(stayed: 3, left: 2, online: 2),
                              places: [.init(kind: "model", count: 2, provider: "anthropic")])
        let local = WeekRecord(bot: "nowhere", since: since)
        let note = WeeklyNote.build([
            WeeklyHelperInput(profile: "career", name: "Scout", record: busy, spend: ModelSpend(dollars: 4.2)),
            WeeklyHelperInput(profile: "nowhere", name: "Mason", record: local),
            WeeklyHelperInput(profile: "private", name: "Moss", record: local, spend: ModelSpend(dollars: 9)),
        ], isPrivate: { $0 == "private" })
        #expect(note.spend == 4.2)
        #expect(note.spendLine?.contains("4.20") == true)
        #expect(note.spendLine?.hasPrefix("This week: about") == true)
        let scout = try #require(note.helpers.first { $0.profile == "career" })
        let line = try #require(scout.did.first { $0.kind == .spend })
        #expect(line.text.hasPrefix("About") && line.text.contains("4.20"))
        #expect(note.quiet == ["Mason"])
        // Nothing priced anywhere: no line at all.
        let free = WeeklyNote.build([WeeklyHelperInput(profile: "nowhere", name: "Mason", record: local)], isPrivate: { _ in false })
        #expect(free.spend == nil && free.spendLine == nil)
        // Under a cent is said as such, never as $0.00.
        #expect(WeeklyWords.spend(0.004).hasPrefix("Under"))
    }
}
