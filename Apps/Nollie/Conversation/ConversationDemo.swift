import SwiftUI
import NollieCore

/// Opens the app on the new conversation screen instead of its usual first screen, when the launch flag asks for
/// it (Debug builds only). Otherwise it draws `content` unchanged.
struct ConversationDemoGate<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if DEBUG
        if let demo = ConversationDemo.launched {
            ConversationDemoRoot(demo: demo)
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

#if DEBUG
/// The new conversation screen on a synthetic chat, for measuring it (`Docs/specs/conversation-ui.md`):
///
///   -nollie-demo-new-chat <rows>       a lineage of that many stored rows in up to four segments
///   -nollie-demo-latency <seconds>     each history page takes that long (default 0)
///   -nollie-demo-token-rate <n>        tokens a second in a streamed reply (default 50)
///   -nollie-demo-reply-tokens <n>      tokens in a streamed reply (default 400)
///   -nollie-demo-no-card               no approval waiting
///   -nollie-demo-autosend <seconds>    sends a message by itself that long after opening
///   -nollie-demo-page <rows>           the window's page size (default 100; capacity three pages)
///   -nollie-demo-card <kind>           the question waiting: approval (default), clarify, choices or value
///
/// A real `ConversationEngine` runs it: the window pages an in-memory history, and a scripted link answers the
/// attach, waits on one approval and streams a reply to whatever is sent.
@MainActor
@Observable
final class ConversationDemo {
    static let launched: ConversationDemo? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-nollie-demo-new-chat"), i + 1 < args.count, let rows = Int(args[i + 1]), rows > 0 else {
            return nil
        }
        func number(_ flag: String) -> Double? {
            guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
            return Double(args[j + 1])
        }
        return ConversationDemo(rows: rows, latency: number("-nollie-demo-latency") ?? 0,
                                tokenRate: number("-nollie-demo-token-rate") ?? 50,
                                replyTokens: Int(number("-nollie-demo-reply-tokens") ?? 400),
                                card: args.contains("-nollie-demo-no-card") ? nil : (args.firstIndex(of: "-nollie-demo-card").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "approval"),
                                autosend: number("-nollie-demo-autosend"),
                                page: Int(number("-nollie-demo-page") ?? 100))
    }()

    let engine: ConversationEngine
    let history: MemoryConversationHistory
    private let link: ConversationDemoLink
    private let notices: AsyncStream<GatewayNotice>
    private let launchedAt = ContinuousClock.now

    /// Pages asked for and not answered yet, and answered so far, polled from the history.
    private(set) var pendingPages = 0
    private(set) var servedPages = 0
    /// From the demo's creation (as the first window opens), in milliseconds: to the engine starting, to the
    /// first rows in the transcript, and to the run loop turn after they were drawn.
    private(set) var startedInMs: Int?
    private(set) var rowsInMs: Int?
    private(set) var openedInMs: Int?
    private var started = false
    /// Frame pacing on the main thread, for the smoothness check.
    let frames = ConversationFrameWatch()

    private let autosend: Double?

    init(rows: Int, latency: Double, tokenRate: Double, replyTokens: Int, card: String?, autosend: Double? = nil, page: Int = 100) {
        self.autosend = autosend
        let lineage = ConversationDemoLineage(rows: rows)
        history = MemoryConversationHistory(segments: lineage.segments, parents: lineage.parents,
                                            latency: .milliseconds(Int(latency * 1000)))
        let (stream, continuation) = AsyncStream.makeStream(of: GatewayNotice.self)
        notices = stream
        link = ConversationDemoLink(tip: lineage.tip, history: history, notices: continuation, tokenRate: tokenRate,
                                    replyTokens: replyTokens, card: card)
        engine = ConversationEngine(key: "demo", sessionId: lineage.tip, link: link, history: history, lineageSource: history,
                                    store: MemoryConversationCacheStore(),
                                    configuration: .init(window: .init(pageSize: page, capacity: page * 3, prefetchMargin: max(page * 2 / 5, 10))))
    }

    func start() async {
        guard !started else { return }
        started = true
        let engine = engine, notices = notices
        Task { await engine.run(notices) }
        startedInMs = elapsedMs()
        frames.start()
        await engine.start()
        if let autosend {
            Task {
                try? await Task.sleep(for: .milliseconds(Int(autosend * 1000)))
                engine.send("How does it look?")
            }
        }
        while !Task.isCancelled {
            pendingPages = await history.pending
            servedPages = await history.pagesServed
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func elapsedMs() -> Int { Int((ContinuousClock.now - launchedAt) / .milliseconds(1)) }

    func drew() {
        guard rowsInMs == nil, !engine.transcript.isEmpty else { return }
        rowsInMs = elapsedMs()
        // The rows are laid out in this pass of the run loop; the following pass runs after the frame is committed.
        DispatchQueue.main.async { DispatchQueue.main.async { self.openedInMs = self.elapsedMs() } }
    }

    /// What the measuring test reads: rows the screen holds, the ends of the window, pages and the streamed reply.
    var metrics: String {
        let transcript = engine.transcript
        let reply = engine.state.rows.last(where: { $0.reply?.streaming == true })?.reply?.text.count ?? 0
        return ["rows=\(transcript.count)",
                "first=\(transcript.first?.id ?? "-")",
                "last=\(transcript.last?.id ?? "-")",
                "newest=\(engine.historyAtNewestEnd ? 1 : 0)",
                "oldest=\(engine.historyAtOldestEnd ? 1 : 0)",
                "pending=\(pendingPages)",
                "served=\(servedPages)",
                "streaming=\(reply)",
                "running=\(engine.state.running ? 1 : 0)",
                "started=\(startedInMs.map(String.init) ?? "-")",
                "rowsin=\(rowsInMs.map(String.init) ?? "-")",
                "opened=\(openedInMs.map(String.init) ?? "-")",
                frames.line, ConversationListTiming.line].joined(separator: " ")
    }
}

struct ConversationDemoRoot: View {
    let demo: ConversationDemo

    var body: some View {
        NavigationStack {
            ConversationScreen(engine: demo.engine)
                .navigationTitle("Nollie")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .overlay(alignment: .topLeading) { ConversationDemoMetrics(demo: demo) }
        }
        .task { await demo.start() }
        .onChange(of: demo.engine.transcript.isEmpty) { _, _ in demo.drew() }
    }
}

/// Counts frames the main thread delivered late: each frame that came more than half a frame after it was due
/// adds its lateness to `hitchMs`. Hitch time over elapsed time is the hitch ratio Apple's tools report.
@MainActor
@Observable
final class ConversationFrameWatch {
    private(set) var frames = 0
    private(set) var hitchMs = 0.0
    private(set) var longestMs = 0.0
    private(set) var late = 0
    @ObservationIgnored private var last: CFTimeInterval?
    @ObservationIgnored private var expected: CFTimeInterval = 1.0 / 60
    @ObservationIgnored private var published = Date()
    #if os(iOS)
    @ObservationIgnored private var link: CADisplayLink?
    #endif

    func start() {
        #if os(iOS)
        guard link == nil else { return }
        let link = CADisplayLink(target: Ticker(watch: self), selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        #endif
    }

    // Counted quietly and published a few times a second, so watching does not redraw the screen every frame.
    @ObservationIgnored private var counts = (frames: 0, hitch: 0.0, longest: 0.0, late: 0)
    /// The same, counted only while the list is dragged or coasts (`ConversationListTiming.moving`): the hitch
    /// ratio while scrolling, as Apple's scroll metric counts it. The test's own reads of the accessibility tree
    /// happen while the app is idle, so they stay out of it.
    @ObservationIgnored private var scrolling = (frames: 0, hitch: 0.0, late: 0, ms: 0.0)
    private(set) var scrollingLine = ""

    fileprivate func tick(timestamp: CFTimeInterval, target: CFTimeInterval) {
        defer { last = timestamp; expected = max(target - timestamp, 1.0 / 120) }
        guard let last else { return }
        let gap = timestamp - last
        counts.frames += 1
        counts.longest = max(counts.longest, gap * 1000)
        let isLate = gap > expected * 1.5
        if isLate {
            counts.hitch += (gap - expected) * 1000
            counts.late += 1
        }
        if ConversationListTiming.moving {
            scrolling.frames += 1
            scrolling.ms += gap * 1000
            if isLate {
                scrolling.hitch += (gap - expected) * 1000
                scrolling.late += 1
            }
        }
        if Date().timeIntervalSince(published) > 0.25 {
            published = Date()
            frames = counts.frames
            hitchMs = counts.hitch
            longestMs = counts.longest
            late = counts.late
            scrollingLine = "scrollframes=\(scrolling.frames) scrolllate=\(scrolling.late) scrollhitchms=\(Int(scrolling.hitch)) scrollms=\(Int(scrolling.ms))"
        }
    }

    var line: String { "frames=\(frames) late=\(late) hitchms=\(Int(hitchMs)) longestms=\(Int(longestMs)) \(scrollingLine)" }

    #if os(iOS)
    private final class Ticker: NSObject {
        weak var watch: ConversationFrameWatch?
        init(watch: ConversationFrameWatch) { self.watch = watch }
        @MainActor @objc func tick(_ link: CADisplayLink) { watch?.tick(timestamp: link.timestamp, target: link.targetTimestamp) }
    }
    #endif
}

/// For the measuring test only: invisible, read through the accessibility tree. A view of its own, so its
/// updates redraw only itself.
private struct ConversationDemoMetrics: View {
    let demo: ConversationDemo

    var body: some View {
        Text(demo.metrics)
            .font(.system(size: 2))
            .foregroundStyle(.clear)
            .frame(width: 2, height: 2)
            .accessibilityIdentifier("conversation.metrics")
            .allowsHitTesting(false)
    }
}

// MARK: - The synthetic chat

/// A made-up conversation of `rows` stored rows, the same every time: short and long messages, code, tool steps
/// (with the assistant rows that only called them, which the screen hides), in up to four segments.
struct ConversationDemoLineage {
    var segments: [String: [ConversationHistoryRow]] = [:]
    var parents: [String: String] = [:]
    var tip: String

    init(rows count: Int) {
        let segmentCount = count >= 400 ? 4 : count >= 40 ? 2 : 1
        let names = (0..<segmentCount).map { "demo-s\($0)" }
        tip = names[names.count - 1]
        for index in 1..<names.count { parents[names[index]] = names[index - 1] }
        var rows: [ConversationHistoryRow] = []
        var turn = 0
        while rows.count < count {
            rows.append(contentsOf: Self.turn(turn))
            turn += 1
        }
        rows.removeLast(rows.count - count)
        for (offset, var row) in rows.enumerated() {
            let id = offset + 1
            let segment = names[min(offset * segmentCount / count, segmentCount - 1)]
            row.address = ConversationRowAddress(segment: segment, rowId: id)
            segments[segment, default: []].append(row)
        }
    }

    private static func row(_ role: String, _ text: String, tool: String? = nil, called: [String] = []) -> ConversationHistoryRow {
        ConversationHistoryRow(address: ConversationRowAddress(segment: "", rowId: 0), role: role, text: text, toolName: tool,
                               toolCallId: tool.map { "call-\($0)" }, calledTools: called)
    }

    /// The rows of turn `n`: one of six shapes, with words picked by `n`.
    private static func turn(_ n: Int) -> [ConversationHistoryRow] {
        let ask = asks[n % asks.count]
        switch n % 6 {
        case 0:
            return [row("user", ask), row("assistant", shortReplies[n % shortReplies.count])]
        case 1:
            return [row("user", longAsks[n % longAsks.count]), row("assistant", longReplies[n % longReplies.count])]
        case 2:
            return [row("user", ask), row("assistant", "", called: ["terminal"]),
                    row("tool", "exit 0", tool: "terminal"), row("assistant", codeReplies[n % codeReplies.count])]
        case 3:
            return [row("user", ask), row("assistant", "", called: ["web_search", "web_extract"]),
                    row("tool", "5 results", tool: "web_search"), row("tool", "page text", tool: "web_extract"),
                    row("assistant", longReplies[(n + 1) % longReplies.count])]
        case 4:
            return [row("user", shortAsks[n % shortAsks.count]), row("assistant", shortReplies[(n + 2) % shortReplies.count])]
        default:
            return [row("user", ask), row("assistant", "", called: ["read_file"]), row("tool", "112 lines", tool: "read_file"),
                    row("assistant", "", called: ["patch"]), row("tool", "1 file changed", tool: "patch"),
                    row("assistant", codeReplies[(n + 1) % codeReplies.count])]
        }
    }

    static let shortAsks = ["Thanks!", "Sounds good.", "Yes please.", "And tomorrow?", "Perfect."]

    static let asks = [
        "Can you check whether the backup ran last night?",
        "What should I plant along the north fence?",
        "Summarize the notes from Tuesday's call.",
        "Is there a quicker way to rename all these photos?",
        "Find me a quiet café near the station that opens early.",
        "Why does the build fail only on the second run?",
        "Remind me what we decided about the bike lights.",
    ]

    static let longAsks = [
        "I'm planning four days in Lisbon in March. I like walking more than tours, good bread, and one day out of the city. Could you sketch a loose plan and tell me what to book ahead?",
        "The sourdough came out dense again. I fed the starter at 8, mixed at 2, shaped at 7 and baked straight from the fridge the next morning. What would you change first?",
        "Our home network drops every evening around nine. The router is three years old, there are about twenty devices, and it only happens on the 5 GHz band. Where would you start?",
    ]

    static let shortReplies = [
        "Done. It finished at 2:14 and took eleven minutes.",
        "You're welcome!",
        "Yes. Same time works, and it should be dry by noon.",
        "Got it, I'll keep that in mind.",
        "Shade-tolerant ones: ferns, hostas and a climbing hydrangea on the fence itself.",
    ]

    static let longReplies = [
        """
        Here's a loose shape for it:

        **Day 1.** Alfama and Graça on foot, ending at a miradouro for sunset. Bread at a padaria on the way.
        **Day 2.** Belém in the morning, then the riverside walk back towards Cais do Sodré.
        **Day 3.** A day out: Sintra by train, early, before the crowds.
        **Day 4.** Slow morning, the market, and whatever you missed.

        Book the Sintra palace tickets and one dinner ahead. Everything else can stay open.
        """,
        """
        Dense crumb with that schedule usually means the bulk ferment was too short for the kitchen's temperature. Five hours is fine at 26 °C but not at 20 °C.

        I'd change one thing first: let the bulk run until the dough has grown by about half and feels airy at the edges, however long that takes. Keep the shaping and the cold retard as they are.
        """,
        """
        A drop at the same time every evening, only on 5 GHz, points at the radio rather than the line. Two likely causes:

        1. A neighbour's network moving onto your channel when they get home.
        2. The router's automatic channel picker switching and dropping everyone.

        Pin the 5 GHz band to a fixed channel for a few days and see whether the drops stop. If they do, that was it.
        """,
    ]

    static let codeReplies = [
        """
        This renames them by the date they were taken:

        ```bash
        for f in *.jpg; do
          d=$(exiftool -s3 -d '%Y-%m-%d_%H%M%S' -DateTimeOriginal "$f")
          mv -n "$f" "$d.jpg"
        done
        ```

        `-n` keeps it from overwriting two photos taken in the same second.
        """,
        """
        The second run reuses a stale cache. Clearing it before the build fixes it:

        ```swift
        let cache = FileManager.default.temporaryDirectory.appending(path: "build-cache")
        try? FileManager.default.removeItem(at: cache)
        ```

        A better fix is keying the cache by the compiler version, so it clears itself.
        """,
        """
        The backup ran. Here's the line from the log:

        ```
        2026-10-19 02:14:07 backup: 41,203 files, 2.1 GB, 11m 02s, ok
        ```
        """,
    ]
}

// MARK: - The scripted link

/// Stands in for the gateway: answers the attach, asks one approval, and streams a reply to every message at a
/// steady rate, storing the turn in the history when it ends.
actor ConversationDemoLink: ConversationLink {
    private let tip: String
    private let history: MemoryConversationHistory
    private let notices: AsyncStream<GatewayNotice>.Continuation
    private let tokenRate: Double
    private let replyTokens: Int
    /// The kind of question asked on the first attach, nil once asked.
    private var cardWaiting: String?
    private var seq = 0
    private var streaming: Task<Void, Never>?
    private static let runtime = "rt-demo"

    init(tip: String, history: MemoryConversationHistory, notices: AsyncStream<GatewayNotice>.Continuation,
         tokenRate: Double, replyTokens: Int, card: String?) {
        self.tip = tip
        self.history = history
        self.notices = notices
        self.tokenRate = tokenRate
        self.replyTokens = replyTokens
        cardWaiting = card
    }

    func currentPhase() async -> GatewayPhase { .ready }

    func request(_ method: String, _ params: GatewayJSON, timeout: Duration?) async throws -> GatewayJSON {
        switch method {
        case "session.resume":
            if let kind = cardWaiting {
                cardWaiting = nil
                notices.yield(.question(Self.question(kind)))
            }
            return ["session_id": .string(Self.runtime), "stored_session_id": .string(tip), "running": false,
                    "info": ["title": "Nollie", "running": false]]
        case "prompt.submit":
            let text = params["text"]?.stringValue ?? ""
            let userRow = await history.newestRowId + 1
            stream(after: text, userRow: userRow)
            return ["status": "streaming", "user_row_id": .integer(userRow)]
        case "session.interrupt":
            streaming?.cancel()
            return [:]
        default:
            return [:]
        }
    }

    /// The question a demo chat waits on, by kind.
    static func question(_ kind: String) -> GatewayIncomingQuestion {
        switch kind {
        case "clarify":
            return GatewayIncomingQuestion(id: "demo-clarify", method: "clarify", params: [
                "session_id": .string(runtime),
                "questions": [["qid": "day", "question": "Which day suits you for the move?", "choices": ["Saturday", "Sunday"]]],
            ])
        case "choices":
            return GatewayIncomingQuestion(id: "demo-choices", method: "clarify", params: [
                "session_id": .string(runtime),
                "questions": [["qid": "rooms", "question": "Which rooms should I plan for?", "choices": ["Kitchen", "Study", "Garden"],
                               "multi_select": true],
                              ["qid": "note", "question": "Anything I should know?"]],
            ])
        case "value":
            return GatewayIncomingQuestion(id: "demo-value", method: "secret", params: [
                "session_id": .string(runtime), "prompt": "The router's admin password",
            ])
        default:
            return GatewayIncomingQuestion(id: "demo-approval", method: "approval", params: [
                "session_id": .string(runtime), "request_id": "demo-request",
                "command": "rm -rf ~/Library/Caches/com.example.photos",
                "description": "Clear the photo app's cache to free 4.2 GB.",
                "choices": ["once", "session", "always", "deny"],
            ])
        }
    }

    /// Answers as the person gave them, for the measuring tests to read back.
    private(set) var answers: [String: GatewayJSON] = [:]

    func answer(question id: String, method: String, result: GatewayJSON) async { answers[id] = result }
    func decline(question id: String) async {}
    func watch(session: String, profile: String?) async {}
    func unwatch(session: String) async {}

    private func event(_ type: String, _ payload: GatewayJSON = [:]) {
        seq += 1
        notices.yield(.event(GatewayEventEnvelope(type: type, sessionId: Self.runtime, seq: seq, payload: payload)))
    }

    private func stream(after prompt: String, userRow: Int) {
        let tokens = Self.reply(tokens: replyTokens)
        let gap = Duration.seconds(1 / max(tokenRate, 1))
        streaming = Task {
            event("message.start")
            var text = ""
            let clock = ContinuousClock()
            var next = clock.now
            for token in tokens {
                next += gap
                try? await clock.sleep(until: next)
                if Task.isCancelled { break }
                text += token
                event("message.delta", ["text": .string(token)])
            }
            let replyRow = userRow + 1
            await history.append(ConversationHistoryRow(address: ConversationRowAddress(segment: tip, rowId: userRow), role: "user", text: prompt))
            await history.append(ConversationHistoryRow(address: ConversationRowAddress(segment: tip, rowId: replyRow), role: "assistant", text: text))
            event("message.complete", ["text": .string(text), "status": "complete",
                                       "persisted_turn": ["complete": true, "row_ids": [.integer(userRow), .integer(replyRow)],
                                                          "user_row_id": .integer(userRow), "final_assistant_row_id": .integer(replyRow)]])
        }
    }

    /// A reply of about `tokens` tokens: words with their spaces, a paragraph break now and then, and one code block.
    static func reply(tokens: Int) -> [String] {
        let words = ("Here is what I found after looking through everything you sent over this morning. Most of it is in good "
            + "shape and only a few small things need your attention before the weekend.").split(separator: " ").map(String.init)
        var out: [String] = []
        var index = 0
        while out.count < tokens {
            if out.count == tokens / 2 {
                out.append("\n\n```\n")
                out.append("make check\n")
                out.append("```\n\n")
            }
            out.append(words[index % words.count] + " ")
            index += 1
            if index % 37 == 0 { out.append("\n\n") }
        }
        return out
    }
}
#endif
