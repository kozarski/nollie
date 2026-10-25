import Foundation

/// Hermes's own words about compressing a long chat, read into what Nollie shows instead.
/// Nollie keeps one endless main chat, so advice to start a new one is never shown, and the
/// progress lines become one quiet row rather than one row each.
public enum CompressionNotice: Equatable, Sendable {
    /// Summarizing is under way (Hermes repeats this while it works).
    case summarizing
    /// Summarizing finished and the turn goes on.
    case finished
    /// A warning that only makes sense for chats people restart (for example "Consider /new").
    case hidden

    public static let summarizingLine = "Summarizing earlier messages…"
    public static let summarizedRow = "Earlier messages summarized to keep this chat going"

    /// nil: not about compression, shown as it comes.
    public static func read(kind: String, text: String) -> CompressionNotice? {
        let lowered = text.lowercased()
        if kind == "compacting" || lowered.contains("compacting context") { return .summarizing }
        if kind == "compacted" || lowered.contains("context compaction complete") { return .finished }
        if lowered.contains("session compressed") || (lowered.contains("compress") && lowered.contains("/new")) { return .hidden }
        return nil
    }
}
