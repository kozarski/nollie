import SwiftUI
import NollieCore

/// A bot's main chat as a card: its character, what it is doing right now and the last thing it said.
/// It sits on top of Chats, so the one continuous conversation is always a tap away. While the
/// bot works, a light runs round the card's edge.
struct MainChatCard: View {
    let runtime: GatewayRuntime
    let profile: String
    var compact: Bool = MainChatCard.compactByDefault
    var onOpen: () -> Void

    #if os(macOS)
    static let compactByDefault = true
    #else
    static let compactByDefault = false
    #endif

    @State private var storedID: String?
    @State private var lastText: String?
    @State private var lastDate: Date?
    @State private var next: NextRun?
    @State private var taps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var label: String { runtime.profiles.first { $0.name == profile }?.shownName ?? profile }
    private var chat: ChatSession? { storedID.flatMap { runtime.chatForStored($0) } }
    private var working: Bool { chat?.isRunning ?? false }
    private var thinking: Bool { working && (chat?.statusLine ?? "Thinking…") == "Thinking…" }
    private var needsYou: Bool { storedID.map { runtime.needsAttention.contains($0) } ?? false }
    /// What the character shows: waiting on you first, else what the chat is doing.
    private var characterState: CharacterState { needsYou ? .needsYou : (chat?.botState ?? .idle) }
    /// Cards this bot has running on the board, when the board has been read.
    private var cardsRunning: Int { runtime.kanban.workers.filter { ($0.profile ?? $0.taskAssignee) == profile }.count }
    private var tint: Color { BotColors.color(for: profile) }
    private var corner: CGFloat { compact ? 18 : 24 }

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 10 : 14) {
            Button { taps += 1; onOpen() } label: {
                HStack(alignment: .center, spacing: compact ? 10 : 14) {
                    BotAvatar(profile: profile, size: compact ? 42 : 58, state: characterState)
                    VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(label).font(compact ? .headline : .title3.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                            if let lastDate {
                                Text(lastDate, format: .relative(presentation: .named))
                                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                        presenceLine
                        if let lastText, !lastText.isEmpty {
                            Text(lastText)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .lineLimit(compact ? 1 : 2)
                                .contentTransition(.opacity)
                        }
                        // What it does next on its own: the soonest of its scheduled jobs.
                        if !compact, let next, next.date > Date() {
                            HStack(spacing: 5) {
                                Image(systemName: "clock").imageScale(.small)
                                Text("Next: \(next.name)").lineLimit(1)
                                Text(next.date, format: Calendar.current.isDateInToday(next.date) ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute())
                                    .monospacedDigit().layoutPriority(1)
                            }
                            .font(.caption).foregroundStyle(.tertiary)
                            .padding(.top, 2)
                            .transition(.opacity)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label), main chat")
            .accessibilityValue([presenceText, next.map { "next, \($0.name)" }].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Opens your conversation with \(label).")
            .accessibilityIdentifier("chats.mainChat")
        }
        .padding(compact ? 12 : 16)
        .background {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.20), tint.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay { edge }
        .animation(.snappy, value: working)
        .animation(.snappy, value: needsYou)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .task(id: "\(runtime.connection.id.uuidString)|\(profile)") { await load() }
        // A reply finishing in the main chat (open on this device) shows here at once.
        .onReceive(NotificationCenter.default.publisher(for: .hermesReplyCompleted)) { note in
            guard let id = note.userInfo?["storedID"] as? String, id == storedID,
                  let text = note.userInfo?["text"] as? String, !text.isEmpty else { return }
            withAnimation(.snappy) { lastText = Self.oneLine(text); lastDate = Date() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesSessionsChanged)) { _ in
            Task { await loadPreview(); await loadNext() }
        }
        // Once the next job's time has passed, ask again for the one after it.
        .task(id: next?.date) {
            guard let due = next?.date else { return }
            let wait = due.timeIntervalSinceNow + 90
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if !Task.isCancelled { await loadNext() }
        }
    }

    /// One line on the bot's situation: anything waiting on the person comes first, then the current work.
    @ViewBuilder private var presenceLine: some View {
        if needsYou {
            Label("Needs you", systemImage: "exclamationmark.bubble.fill")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.red).lineLimit(1)
        } else if working, let storedID {
            ChatGoalLine(storedID: storedID, step: chat?.statusLine ?? (thinking ? "Thinking…" : "Replying…"))
        } else if cardsRunning > 0 {
            Label(cardsRunning == 1 ? "Working on a card" : "Working on \(cardsRunning) cards", systemImage: "square.stack.3d.up.fill")
                .font(.subheadline).foregroundStyle(tint).lineLimit(1)
        } else {
            Label("All caught up", systemImage: "checkmark.circle")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var presenceText: String {
        if needsYou { return "Needs you" }
        if working { return chat?.statusLine ?? "Working" }
        if cardsRunning > 0 { return cardsRunning == 1 ? "Working on a card" : "Working on \(cardsRunning) cards" }
        return "All caught up"
    }

    /// A light that runs round the edge while the bot works; red when it needs Corey.
    @ViewBuilder private var edge: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        if needsYou {
            shape.strokeBorder(Color.red.opacity(0.55), lineWidth: 1.5)
        } else if working && !reduceMotion {
            TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
                shape.strokeBorder(
                    AngularGradient(colors: [tint, tint.opacity(0.05), tint.opacity(0.35), tint.opacity(0.05), tint],
                                    center: .center, angle: .degrees(turn * 360)),
                    lineWidth: 2)
            }
            .allowsHitTesting(false)
        } else {
            shape.strokeBorder(tint.opacity(working ? 0.6 : 0.22), lineWidth: 1)
        }
    }

    private func load() async {
        storedID = await runtime.mainChatID(profile: profile)
        await loadPreview()
        await loadNext()
    }

    struct NextRun: Equatable {
        var name: String
        var date: Date
    }

    /// The soonest run among the bot's enabled scheduled jobs.
    private func loadNext() async {
        guard let r: JSONValue = try? await runtime.api.get("/api/cron/jobs", profile: profile) else { return }
        let jobs = r["jobs"]?.arrayValue ?? r["items"]?.arrayValue ?? r.arrayValue ?? []
        let now = Date()
        let soonest = jobs.compactMap { j -> NextRun? in
            guard j["enabled"]?.boolValue != false,
                  let s = j["next_run_at"]?.stringValue ?? j["nextRunAt"]?.stringValue,
                  let d = Self.date(s), d > now else { return nil }
            return NextRun(name: Self.jobName(j["name"]?.stringValue), date: d)
        }.min { $0.date < $1.date }
        withAnimation(.snappy) { next = soonest }
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// A job's name as people read it: Bot Mode's "[bot:name] " routine prefix dropped.
    static func jobName(_ raw: String?) -> String {
        var name = (raw ?? "").trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("[bot:"), let end = name.firstIndex(of: "]") { name = String(name[name.index(after: end)...]).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? "Scheduled job" : name
    }

    /// A bot's Bot Chat, the session Hermes keeps as its main chat: titled "Bot Chat", or
    /// "Bot Chat #2" and on once compression has carried it on.
    static func isMainTitle(_ title: String?) -> Bool {
        guard let t = title?.trimmingCharacters(in: .whitespaces) else { return false }
        if t == "Bot Chat" { return true }
        guard t.hasPrefix("Bot Chat #") else { return false }
        return Int(t.dropFirst("Bot Chat #".count)) != nil
    }

    /// What a main chat is called on screen.
    static func shownTitle(_ title: String) -> String { isMainTitle(title) ? "Main chat" : title }

    /// The last thing the bot said in its main chat: fresh from the gateway, else what this
    /// device kept of the thread.
    private func loadPreview() async {
        guard let sid = storedID else { return }
        guard let reply = await BotsHome.lastReply(runtime, storedID: sid, profile: profile), !reply.text.isEmpty else { return }
        withAnimation(.snappy) {
            lastText = reply.text
            if let date = reply.date { lastDate = date }
        }
    }

    /// Plain text on one line, cut to fit a card.
    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > 220 ? String(flat.prefix(219)) + "…" : flat
    }
}
