import Foundation

/// How far a running tool has got, from Hermes 0.23's `tool.progress` (an MCP server's progress notices,
/// at most two a second): `progress`, and `total`, `percent` and `message` when the tool gives them.
public struct ToolProgress: Codable, Hashable, Sendable {
    public var done: Double
    public var total: Double?
    public var percent: Int?
    public var message: String?

    public init(done: Double, total: Double? = nil, percent: Int? = nil, message: String? = nil) {
        (self.done, self.total, self.percent, self.message) = (done, total, percent, message)
    }

    /// Read from the event's payload; nil without a number to show.
    public init?(progress: Double?, total: Double?, percent: Int?, message: String?) {
        guard let progress, progress.isFinite, progress >= 0 else { return nil }
        self.init(done: progress, total: total.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                  percent: percent.map { min(max($0, 0), 100) }, message: message?.isEmpty == true ? nil : message)
    }

    public init?(_ payload: JSONValue) {
        self.init(progress: payload["progress"]?.doubleValue, total: payload["total"]?.doubleValue,
                  percent: payload["percent"]?.intValue, message: payload["message"]?.stringValue)
    }

    /// Between 0 and 1, when the tool says how much there is in all.
    public var fraction: Double? {
        if let total { return min(max(done / total, 0), 1) }
        if let percent { return Double(percent) / 100 }
        return nil
    }

    /// A few words for the row: "3 of 10", "40%", or just the count so far.
    public var shortText: String {
        let count = Self.whole(done)
        if let total, let all = Self.whole(total), let count {
            return String(localized: "\(count) of \(all)", table: "Core", comment: "How far a tool has got: steps done of all steps")
        }
        if let percent { return String(localized: "\(percent)%", table: "Core", comment: "How far a tool has got, in percent") }
        return count.map { String(localized: "\($0) so far", table: "Core", comment: "How many steps a tool has done, with no total known") }
            ?? done.formatted(.number.precision(.fractionLength(0...1)))
    }

    private static func whole(_ value: Double) -> Int? {
        value == value.rounded() && abs(value) < 1e9 ? Int(value) : nil
    }
}
