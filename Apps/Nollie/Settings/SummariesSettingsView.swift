import FoundationModels
import NollieCore
import SwiftUI

/// The three things the on-device model writes, each with its switch in storage.
@MainActor
private struct SummaryParts: DynamicProperty {
    @AppStorage(ChatSummarizer.titlesKey) var titles = ChatSummarizer.titlesOn
    @AppStorage(ChatSummarizer.previewsKey) var previews = ChatSummarizer.previewsOn
    @AppStorage(ChatGoals.enabledKey) var statusLine = ChatGoals.isOn

    var anyOn: Bool { titles || previews || statusLine }

    /// One switch for all three, so none is left following another by surprise. It reads as on
    /// while titles or previews are.
    var everything: Binding<Bool> {
        Binding(
            get: { titles || previews },
            set: { newValue in
                titles = newValue
                previews = newValue
                statusLine = newValue
            })
    }
}

/// Settings › Appearance › Chat summaries: what the on-device model is doing now, and one switch
/// for all of it. Each part on its own, and forgetting them, wait behind Advanced.
struct SummariesSettingsView: View {
    private var parts = SummaryParts()

    private static let facts = [
        Fact(symbol: "textformat", word: "Titles"),
        Fact(symbol: "text.alignleft", word: "Previews"),
        Fact(symbol: "lock.fill", word: "Only on \(DeviceWords.this)"),
    ]

    var body: some View {
        SettingsPage("summaries.page") {
            SummariesHero(reading: SummariesReading.now(on: parts.titles || parts.previews))
                .testID("summaries.status")
            FactStrip(facts: Self.facts, id: "summaries.facts")
            GlassSwitch("Summaries", isOn: parts.everything, id: "summaries.switch")
                .disabled(!ChatSummarizer.isAvailable)
            AdvancedLink(id: "summaries.advanced") { SummariesAdvancedPage().untitledPage() }
        }
    }
}

/// Where the summaries stand: can't run here, off, writing, or up to date.
private enum SummariesReading: Equatable {
    case needs(String), off, writing(current: Int, total: Int), upToDate(Int)

    /// What is true now, from the device and the summarizer.
    @MainActor static func now(on: Bool) -> SummariesReading {
        if ChatSummarizer.unavailableReason != nil { return .needs(whyNot) }
        if !on { return .off }
        let work = ChatSummarizer.shared.progress
        return work.isWorking
            ? .writing(current: work.current, total: work.total)
            : .upToDate(ChatSummarizer.shared.summaries.count)
    }

    /// Why Apple Intelligence can't write here, in a few words.
    private static var whyNot: String {
        switch SystemLanguageModel.default.availability {
        case .unavailable(.deviceNotEligible): "\(DeviceWords.This) can't run it."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn it on in \(DeviceWords.settings) first."
        case .unavailable(.modelNotReady): "It's still downloading."
        default: "It isn't available right now."
        }
    }

    /// Symbol, title, line and colour, side by side.
    var face: (symbol: String, title: String, line: String, tint: Color) {
        switch self {
        case .needs(let why):
            ("apple.intelligence", "Needs Apple Intelligence", why, .orange)
        case .off:
            ("sparkles", "Summaries off", "Nollie can name and sum up your chats.", Ink.text2)
        case .writing(_, 1):
            ("sparkles", "Writing summaries", "One chat.", .nollie)
        case .writing(let current, let total):
            ("sparkles", "Writing summaries", "\(current) of \(total) chats.", .nollie)
        case .upToDate(let count):
            ("checkmark.seal.fill", "Up to date", Self.doneLine(count), .green)
        }
    }

    private static func doneLine(_ count: Int) -> String {
        switch count {
        case 0: "New chats get one as you go."
        case 1: "1 chat, summed up on \(DeviceWords.this)."
        default: "\(count) chats, summed up on \(DeviceWords.this)."
        }
    }
}

/// The top of Summaries.
private struct SummariesHero: View {
    var reading: SummariesReading

    var body: some View {
        let face = reading.face
        PageHero(symbol: face.symbol, title: face.title, line: face.line, tint: face.tint, id: "summaries.hero")
    }
}

/// Summaries › Advanced: each part on its own, and forgetting every summary written so far. The
/// top says which parts are on.
private struct SummariesAdvancedPage: View {
    private var parts = SummaryParts()
    @State private var forgotten = false
    @AppStorage(QuickAnswers.enabledKey) private var quickAnswers = true

    /// Which parts are on, in a few words: "All three on", "Titles only", "Titles and previews".
    private var heroTitle: String {
        guard ChatSummarizer.isAvailable else { return "Needs Apple Intelligence" }
        let names = [(parts.titles, "titles"), (parts.previews, "previews"), (parts.statusLine, "status line")]
            .compactMap { $0.0 ? $0.1 : nil }
        guard let first = names.first else { return "All three off" }
        let lead = first.prefix(1).uppercased() + first.dropFirst()
        switch names.count {
        case 3: return "All three on"
        case 1: return lead + " only"
        default: return lead + " and " + names[1]
        }
    }

    var body: some View {
        let available = ChatSummarizer.isAvailable
        SettingsPage("summaries.advanced.page") {
            PageHero(symbol: available ? "sparkles" : "apple.intelligence",
                     title: heroTitle,
                     line: available ? (forgotten ? "Every summary is forgotten." : "Written only on \(DeviceWords.this).") : nil,
                     tint: available ? (parts.anyOn ? .nollie : Ink.text2) : .orange,
                     id: "summaries.advanced.hero")
            VStack(spacing: 14) {
                GlassStack {
                    GlassSwitch("Titles", isOn: parts.$titles, id: "summaries.titles")
                    GlassSwitch("Previews", isOn: parts.$previews, id: "summaries.previews")
                    GlassSwitch("Status line", isOn: parts.$statusLine, id: "summaries.goals")
                }
                .disabled(!available)
                PageNote("The status line says what a working bot is trying to get done.")
            }
            VStack(spacing: 14) {
                GlassSwitch("Quick answers", isOn: $quickAnswers, id: "summaries.quickAnswers")
                    .disabled(!available)
                PageNote(DeviceWords.isMac ? "Answers on \(DeviceWords.this) during setup. Talk only."
                                           : "Answers on \(DeviceWords.this) when your Mac is out of reach. Talk only.")
            }
            GlassButton("Forget every summary", symbol: "trash", value: forgotten ? "Forgotten" : nil,
                        role: .destructive, id: "summaries.forget") {
                ChatSummarizer.shared.forgetAll()
                forgotten = true
            }
            .disabled(forgotten)
        }
    }
}
