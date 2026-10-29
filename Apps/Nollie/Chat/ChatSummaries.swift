import FoundationModels
import SwiftUI
import NollieCore

/// Nollie Summaries (beta): titles and short previews for the Chats list, written by the model
/// built into this device. It stays on the device and never writes to the gateway. Switch it off
/// and the gateway's own text returns. Each chat is rewritten only after new activity.
@Observable @MainActor
final class ChatSummarizer {
    private static let base = "chats.aiSummaries"
    static let enabledKey = base
    /// Titles and previews each have their own switch. Until one is set, it copies the old
    /// all-in-one switch.
    static let titlesKey = base + ".titles"
    static let previewsKey = base + ".previews"
    static let shared = ChatSummarizer()

    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? UserDefaults.standard.bool(forKey: enabledKey)
    }
    static var titlesOn: Bool { flag(titlesKey) }
    static var previewsOn: Bool { flag(previewsKey) }

    struct Summary: Codable, Equatable {
        var title: String
        var summary: String
        var stamp: Double
    }

    /// Debug builds can pass `-nollie-test-summaries`. A simulator has no on-device model, so each
    /// chat then waits two seconds and gets stand-in text, which lets the progress strip be seen.
    static var pretend: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-nollie-test-summaries")
        #else
        false
        #endif
    }

    private(set) var summaries = SummaryCache.load()
    /// Feeds the strip above the list and the status line in Settings.
    private(set) var progress = SummaryProgress()
    /// Set when a batch of two or more chats completes, so "up to date" can show briefly.
    private(set) var finishedAt: Date?

    private struct Job {
        var session: StoredSession
        var runtime: GatewayRuntime
        var profile: String?
    }

    private var inFlight: Set<String> = []
    private var waiting: [Job] = []
    /// A single background worker empties the queue; running several together made the list stutter.
    private var worker: Task<Void, Never>?

    /// True while the chat is waiting its turn or being written.
    func isWorking(_ key: String) -> Bool { inFlight.contains(key) }

    var enabled: Bool { Self.titlesOn || Self.previewsOn }

    // MARK: Availability

    /// Needs Apple Intelligence switched on and its model downloaded.
    static var isAvailable: Bool {
        pretend || SystemLanguageModel.default.availability == .available
    }

    static var unavailableReason: String? {
        if pretend { return nil }
        guard case .unavailable(let why) = SystemLanguageModel.default.availability else { return nil }
        switch why {
        case .deviceNotEligible: return String(localized: "Apple Intelligence doesn't work on this device.")
        case .appleIntelligenceNotEnabled:
            return String(localized: "First, switch on Apple Intelligence in \(DeviceWords.settings).", comment: "The name of the Settings app follows in")
        case .modelNotReady: return String(localized: "Apple Intelligence is still getting its model ready.")
        default: return String(localized: "Apple Intelligence isn't available at the moment.")
        }
    }

    // MARK: Reading

    /// The text a row displays. A half that is switched off falls back to the gateway's text, and
    /// a title the person chose is left alone.
    func shown(_ summary: Summary?, title: String, preview: String, renamed: Bool = false) -> Summary? {
        guard enabled, let summary else { return nil }
        let useTitle = Self.titlesOn && !renamed
        return Summary(title: useTitle ? Self.plain(summary.title) : title,
                       summary: Self.previewsOn ? Self.plain(summary.summary) : preview,
                       stamp: summary.stamp)
    }

    /// Picks the title to save. A title already made sticks, so it stays put while the preview
    /// moves on; failing that the new draft, then the gateway's title.
    static func storedTitle(previous: Summary?, draft: String, fallback: String) -> String {
        let candidates = [previous?.title ?? "", draft, fallback].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return candidates.first { !$0.isEmpty } ?? fallback
    }

    /// Strips the backticks and double asterisks the model likes to add, as a list row would
    /// print them literally.
    static func plain(_ text: String) -> String {
        text.components(separatedBy: "`").joined().components(separatedBy: "**").joined()
    }

    /// A saved summary, but only when the chat has not moved since it was written.
    func summary(for session: StoredSession) -> Summary? {
        guard enabled, let saved = summaries[session.id] else { return nil }
        return saved.stamp == (session.lastActive ?? 0) ? saved : nil
    }

    /// Clears everything saved. Rows show the gateway's text until new summaries arrive.
    func forgetAll() {
        summaries = [:]
        SummaryCache.clear()
    }

    // MARK: Writing

    /// Queues a background rewrite of this chat's summary unless it is already current or queued.
    func refresh(_ session: StoredSession, runtime: GatewayRuntime, profile: String?) {
        let current = summaries[session.id]?.stamp == (session.lastActive ?? 0)
        guard enabled, Self.isAvailable, !inFlight.contains(session.id), !current else { return }
        inFlight.insert(session.id)
        waiting.append(Job(session: session, runtime: runtime, profile: profile))
        progress.queued()
        startWorker()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task(priority: .utility) {
            while !waiting.isEmpty {
                let job = waiting.removeFirst()
                await write(job)
                inFlight.remove(job.session.id)
                progress.finished()
                if !progress.isWorking, progress.total > 1 { finishedAt = Date() }
            }
            worker = nil
        }
    }

    private func write(_ job: Job) async {
        let session = job.session
        let earlierTitle = summaries[session.id]
        let made: (title: String, summary: String)?
        if Self.pretend {
            made = await Self.standIn(for: session)
        } else {
            let messages = await SummaryWriter.recentMessages(of: session, runtime: job.runtime, profile: job.profile)
            made = messages.isEmpty ? nil : await SummaryWriter.draft(from: messages)
        }
        guard let made else { return }
        let title = Self.storedTitle(previous: earlierTitle, draft: made.title, fallback: session.displayTitle)
        store(Summary(title: title, summary: made.summary, stamp: session.lastActive ?? 0), for: session.id)
    }

    /// Debug only: waits a moment, then reuses the gateway's own preview as the "summary".
    private static func standIn(for session: StoredSession) async -> (title: String, summary: String) {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let own = session.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ("", own.isEmpty ? "Nothing said yet." : own)
    }

    private func store(_ summary: Summary, for id: String) {
        summaries[id] = summary
        summaries = SummaryCache.save(summaries)
    }
}
