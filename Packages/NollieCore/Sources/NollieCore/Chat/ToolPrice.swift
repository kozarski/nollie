import Foundation

/// The price of a connected app's tool, as Hermes 0.23 says it on the approval it asks for.
///
/// A connected app (an MCP server) may declare what each tool costs (`mcp_servers.<name>.tool_costs`) and a limit for
/// each chat (`spend_limit`, in its own `cost_unit`). Hermes puts the price and the chat's running total only in the
/// words of the approval (`tools/mcp_tool_handlers.py`, sentences from `tools/mcp_tool_costs.py`); no event carries
/// them. Those sentences are fixed in Hermes's source, so they are read here, and only from the approval's first
/// paragraph: the tool's arguments come after it and are never read for a price.
public struct ToolPrice: Equatable, Sendable {
    public var tool: String
    public var server: String
    /// What one call costs, in the app's own unit, as Hermes says it: "5 credits", or a range "2-5 credits".
    public var cost: String
    /// Hermes's "about": a single figure is the app's own estimate.
    public var isEstimate: Bool
    /// What the app says about the cost, like "per page".
    public var note: String?
    /// What this chat has used on this app so far: "10 credits".
    public var used: String?
    /// The app's limit for one chat, as a number ("50"), or with its unit when nothing is used yet ("50 credits").
    public var limit: String?
    /// This call goes past the chat's limit.
    public var overLimit: Bool

    public init(tool: String, server: String, cost: String, isEstimate: Bool = true, note: String? = nil,
                used: String? = nil, limit: String? = nil, overLimit: Bool = false) {
        self.tool = tool; self.server = server; self.cost = cost; self.isEstimate = isEstimate; self.note = note
        self.used = used; self.limit = limit; self.overLimit = overLimit
    }

    public init?(_ approval: ApprovalRequest?) {
        guard let approval, approval.patternKey == nil || approval.patternKey == "mcp_elicitation",
              let command = approval.command else { return nil }
        self.init(words: command)
    }

    /// Reads Hermes's words. Nil unless they open the way Hermes's MCP approvals do and name a price.
    public init?(words: String) {
        let head = words.components(separatedBy: "\n\n").first ?? words
        guard let opening = Self.first(#"^MCP tool '([^']+)' on (?:UNTRUSTED )?server '([^']+)' (?:wants to run\.|would take this chat past its spend limit\.)"#, in: head),
              let price = Self.first(#" Costs (about )?([0-9][0-9,.]*(?:-[0-9][0-9,.]*)? [^.()]{1,32})(?: \(([^)]{1,200})\))?\."#, in: head)
        else { return nil }
        tool = opening[0]
        server = opening[1]
        isEstimate = !price[0].isEmpty
        cost = price[1]
        note = price[2].isEmpty ? nil : price[2]
        overLimit = head.contains("would take this chat past its spend limit.") || head.contains("This call goes past the chat's spend limit.")
        if let spent = Self.first(#"This chat has used about ([0-9][0-9,.]* [^.()]{1,32}) on '[^']+'(?: \(limit ([0-9][0-9,.]*)\))?\."#, in: head) {
            used = spent[0]
            limit = spent[1].isEmpty ? nil : spent[1]
        } else if let cap = Self.first(#"Spend limit for this chat on '[^']+': ([0-9][0-9,.]* [^.()]{1,32})\."#, in: head) {
            used = nil
            limit = cap[0]
        } else {
            used = nil
            limit = nil
        }
    }

    /// The groups of the first match, empty strings for those that didn't take part.
    private static func first(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    // MARK: Words

    /// "About 5 credits", or "2-5 credits" for a range.
    public var costLine: String {
        isEstimate ? String(localized: "About \(cost)", table: "Core", comment: "What one call to a connected app's tool costs, in the app's own unit, like 5 credits")
            : cost
    }

    /// "About 10 credits used in this chat · Limit 50", or "Limit 50 credits in this chat".
    public var spendLine: String? {
        switch (used, limit) {
        case let (used?, limit?):
            String(localized: "About \(used) used in this chat · Limit \(limit)", table: "Core",
                   comment: "A connected app's spending in this chat so far, then the app's limit for one chat")
        case let (used?, nil):
            String(localized: "About \(used) used in this chat", table: "Core", comment: "A connected app's spending in this chat so far")
        case let (nil, limit?):
            String(localized: "Limit \(limit) in this chat", table: "Core", comment: "A connected app's spending limit for one chat")
        case (nil, nil):
            nil
        }
    }
}
