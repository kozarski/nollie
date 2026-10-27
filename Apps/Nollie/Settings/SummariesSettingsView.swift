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
        case .unavailable(.deviceNotEligible): String(localized: "\(DeviceWords.This) can't run it.")
        case .unavailable(.appleIntelligenceNotEnabled): String(localized: "Turn it on in \(DeviceWords.settings) first.")
        case .unavailable(.modelNotReady): String(localized: "It's still downloading.")
        default: String(localized: "It isn't available right now.")
        }
    }

    /// Symbol, title, line and colour, side by side.
    var face: (symbol: String, title: String, line: String, tint: Color) {
        switch self {
        case .needs(let why):
            ("apple.intelligence", String(localized: "Needs Apple Intelligence"), why, .orange)
        case .off:
            ("sparkles", String(localized: "Summaries off"), String(localized: "Nollie can name and sum up your chats."), Ink.text2)
        case .writing(_, 1):
            ("sparkles", String(localized: "Writing summaries"), String(localized: "One chat.", comment: "Writing a summary for one chat"), .nollie)
        case .writing(let current, let total):
            ("sparkles", String(localized: "Writing summaries"), String(localized: "\(current) of \(total) chats."), .nollie)
        case .upToDate(let count):
            ("checkmark.seal.fill", String(localized: "Up to date"), Self.doneLine(count), .green)
        }
    }

    private static func doneLine(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "New chats get one as you go.")
        default: String(localized: "\(count) chats, summed up on \(DeviceWords.this).")
        }
    }
}

/// The top of Summaries.
private struct SummariesHero: View {
    var reading: SummariesReading

    var body: some View {
        let face = reading.face
        PageHero(symbol: face.symbol, title: .verbatim(face.title), line: .verbatim(face.line), tint: face.tint, id: "summaries.hero")
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
        guard ChatSummarizer.isAvailable else { return String(localized: "Needs Apple Intelligence") }
        return switch (parts.titles, parts.previews, parts.statusLine) {
        case (true, true, true): String(localized: "All three on")
        case (true, true, false): String(localized: "Titles and previews")
        case (true, false, true): String(localized: "Titles and status line")
        case (false, true, true): String(localized: "Previews and status line")
        case (true, false, false): String(localized: "Titles only")
        case (false, true, false): String(localized: "Previews only")
        case (false, false, true): String(localized: "Status line only")
        case (false, false, false): String(localized: "All three off")
        }
    }

    var body: some View {
        let available = ChatSummarizer.isAvailable
        SettingsPage("summaries.advanced.page") {
            PageHero(symbol: available ? "sparkles" : "apple.intelligence",
                     title: .verbatim(heroTitle),
                     line: .verbatim(available ? (forgotten ? String(localized: "Every summary is forgotten.")
                                                  : String(localized: "Written only on \(DeviceWords.this).")) : nil),
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
            GlassButton("Forget every summary", symbol: "trash", value: forgotten ? String(localized: "Forgotten", comment: "Every summary was forgotten") : nil,
                        role: .destructive, id: "summaries.forget") {
                ChatSummarizer.shared.forgetAll()
                forgotten = true
            }
            .disabled(forgotten)
        }
    }
}
