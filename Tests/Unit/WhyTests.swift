import Foundation
import SwiftUI
import Testing
@testable import Nollie
@testable import NollieCore

// "Why?" on every Night shift and Papertrail entry: the plain words for each fixed rule, the fallback when a reason
// was never kept, and old receipts and entries still reading as they did. See Docs/specs/night-shift.md and
// Docs/specs/papertrail.md.

/// Words people read never use the add-on's own terms, never a long dash, and never claim more than was kept.
private func plain(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
    for word in ["allowlist", "allow list", "deny_rule", "hardline", "ask_first", "receipt", "Hermes", "\u{2014}", "\u{2013}"] {
        #expect(!text.localizedCaseInsensitiveContains(word), "\"\(word)\" in: \(text)", sourceLocation: sourceLocation)
    }
}

@Suite struct NightShiftWhyTests {
    let schedule = ConversationPost.Run(id: "cron:a:e", kind: "schedule", bot: "career", botName: "Scout", title: "Morning prices")
    let fixed: (Date) -> String = { _ in "17 Oct at 14:02" }

    func why(_ receipt: ConversationPost.Receipt?, status: ConversationPost.Action.Status = .done,
             run: ConversationPost.Run? = nil) -> String {
        let text = NightShiftWhy.explain(.init(tool: "terminal", target: "x", status: status, receipt: receipt), in: run ?? schedule,
                                         moment: fixed)
        plain(text)
        return text
    }

    @Test func everyRuleThatAllowsSaysWhichOneAndWhoAsked() {
        #expect(why(.init(kind: .tool)) == "Scout did this during your schedule \u{201C}Morning prices\u{201D}. "
                + "It's one of the tools this schedule can use, and it doesn't need your yes.")
        #expect(why(.init(kind: .safe)).hasSuffix("The safety check found nothing risky in the command, so it didn't need your yes."))
        #expect(why(.init(kind: .allowlist, detail: "pg_dump")).hasSuffix(
            "It matches \u{201C}pg_dump\u{201D} on your allowed list, so it runs without asking."))
        #expect(why(.init(kind: .allowlist)).hasSuffix("It's on your allowed list, so it runs without asking."))
        #expect(why(.init(kind: .always, detail: "git push", grantedAt: Date(timeIntervalSince1970: 1)))
            .hasSuffix("You chose Always for \u{201C}git push\u{201D} on 17 Oct at 14:02, so it runs without asking."))
        #expect(why(.init(kind: .unknown)).hasSuffix("It was allowed, but Nollie couldn't tell which rule let it through."))
    }

    @Test func anAlwaysNobodySawBeingChosenSaysSoRatherThanGuessAWhen() {
        let text = why(.init(kind: .always, detail: "git push"))
        #expect(text.hasSuffix("You chose Always for \u{201C}git push\u{201D} earlier, so it runs without asking. Nollie didn't see when."))
        #expect(!text.contains("17 Oct"))
    }

    @Test func aHoldSaysWhatNeedsAYesAndWhatYouCanDo() {
        let held = { (ask: String?) in self.why(.init(kind: .held, detail: "ask_first", ask: ask), status: .blocked) }
        #expect(held("send") == "Scout tried this during your schedule \u{201C}Morning prices\u{201D}. "
                + "Sending always waits for your yes, and nobody could answer then, so it wasn't done. "
                + "Ask Scout in a chat if you still want it.")
        #expect(held("buy").contains("Buying always waits for your yes"))
        #expect(held("post").contains("Posting always waits for your yes"))
        #expect(held("delete").contains("Deleting always waits for your yes"))
        #expect(held("unsure").contains("Nollie couldn't tell what this would do"))
        // A hold kept before 1.1 doesn't say which kind: the rule is named in full.
        #expect(held(nil).contains("Anything that sends, buys, posts or deletes always waits for your yes"))
        let rehearsed = why(.init(kind: .held), status: .blocked)
        #expect(rehearsed.hasSuffix("This was a rehearsal, so Nollie wrote it down instead of doing it. "
                                    + "It runs for real once you turn the schedule on."))
    }

    @Test func everyStopSaysWhatStoppedItWithTheRulesOwnWordsWhenKept() {
        let stop = { (detail: String?, rule: String?) in
            self.why(.init(kind: .blocked, detail: detail, rule: rule), status: .blocked)
        }
        #expect(stop("mac", nil).hasSuffix("Schedules and Board tasks never use your Mac's screen or apps, so it was stopped. "
                                           + "Ask Scout in a chat if you want it done."))
        #expect(stop("risky", "recursive delete").contains(
            "The command looked risky (recursive delete), and nobody was there to say yes, so it was stopped."))
        #expect(stop("risky", nil).contains("The command looked risky, and nobody was there"))
        #expect(stop("deny_rule", "curl *").hasSuffix(
            "It matches \u{201C}curl *\u{201D}, one of your rules that says no, so it was stopped."))
        #expect(stop("deny_rule", nil).hasSuffix("One of your rules says no to this, so it was stopped."))
        #expect(stop("hardline", "delete root").hasSuffix("This is never allowed, even when you're there (delete root), so it was stopped."))
        #expect(stop("plugin", nil).hasSuffix("Work nobody watches never changes Nollie's own files, so it was stopped."))
        #expect(stop("other", nil).hasSuffix("The safety check stopped it, and didn't say which rule."))
        #expect(stop(nil, "   ").hasSuffix("The safety check stopped it, and didn't say which rule."))
        #expect(stop("mac", nil).hasPrefix("Scout tried this"), "a stop is never said to have been done")
    }

    @Test func noReceiptSaysTheReasonWasNotKept() {
        #expect(why(nil) == "Scout did this during your schedule \u{201C}Morning prices\u{201D}. Nollie didn't keep the reason for this one.")
        #expect(why(nil, status: .blocked).hasPrefix("Scout tried this"))
    }

    @Test func aFailureIsSaidAfterTheReason() {
        #expect(why(.init(kind: .safe), status: .failed).hasSuffix("so it didn't need your yes. It ran, but it didn't work."))
        #expect(!why(.init(kind: .blocked, detail: "mac"), status: .blocked).contains("didn't work"))
    }

    @Test func whoAskedAndForWhatTask() {
        let board = ConversationPost.Run(id: "board:t1", kind: "board", bot: "career", botName: "Scout", title: "Draft the report")
        #expect(why(.init(kind: .tool), run: board) == "Scout did this for the Board task \u{201C}Draft the report\u{201D}. "
                + "It's one of the tools this task can use, and it doesn't need your yes.")
        let helper = ConversationPost.Run(id: "helper:s", kind: "helper", bot: "nowhere", botName: "", title: "")
        #expect(why(.init(kind: .safe), run: helper).hasPrefix("A helper did this while Nowhere ran a schedule."))
        let untitled = ConversationPost.Run(id: "cron:b:e", kind: "schedule", bot: "default", botName: "Nollie", title: " ")
        #expect(why(.init(kind: .safe), run: untitled).hasPrefix("Nollie did this during one of your schedules."))
        let rehearsal = ConversationPost.Run(id: "cron:c:e", kind: "schedule", bot: "default", botName: "Nollie", title: "Nightly",
                                             outcome: .rehearsal)
        #expect(why(.init(kind: .held), status: .blocked, run: rehearsal).hasPrefix("Nollie tried this in the rehearsal of \u{201C}Nightly\u{201D}."))
    }

    @Test func aRehearsalsLooksSayWhyTheyRan() {
        let card = rehearsalSample().rehearsal!
        let looked = NightShiftWhy.explain(.init(tool: "web_search", target: "2TB NVMe price"), rehearsal: card, looked: true)
        plain(looked)
        #expect(looked == "Scout did this in the rehearsal of \u{201C}Morning prices\u{201D}. Nollie didn't keep the reason for this one. "
                + "A rehearsal lets a schedule look things up, never change anything.")
        let held = NightShiftWhy.explain(.init(tool: "send_message", target: "Price drop", status: .blocked,
                                               receipt: .init(kind: .held)), rehearsal: card, looked: false)
        #expect(held.hasPrefix("Scout tried this in the rehearsal of \u{201C}Morning prices\u{201D}. This was a rehearsal"))
    }

    @Test func theTimeOfAnAlwaysIsInThePersonsOwnFormat() {
        let at = Date(timeIntervalSince1970: 1_792_500_000)
        #expect(NightShiftWhy.moment(at) == at.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
    }

    @Test func eachEntryOpensOnItsOwnAndOnlyOnItsOwnPost() {
        let post = nightShiftSample()
        let rows = [ConversationRow(id: "post:\(post.id)", kind: .post(post))]
        let key = NightShiftWhy.key(run: "cron:244c3b0b8e42:e-80", index: 1)
        #expect(key != NightShiftWhy.key(run: "cron:244c3b0b8e42:e-80", index: 2))
        let items = ConversationListItem.make(transcript: rows, cards: [], activity: nil, atNewestEnd: true,
                                              expanded: [ConversationListItem.expandedKey(post: post.id, run: key),
                                                         ConversationListItem.expandedKey(post: "another", run: key)])
        #expect(items[0] == .post(rows[0], expanded: [key]))
    }
}

@Suite struct ReceiptReasonDecodingTests {
    @Test func newReasonsArriveFromTheAddOn() throws {
        let json = try GatewayJSON.parse(Data(#"""
        {"id": "night-1", "kind": "night_shift", "at": 1792562400, "runs": [{"id": "cron:a:e", "actions": [
          {"tool": "terminal", "target": "rm -rf build", "status": "blocked",
           "receipt": {"kind": "blocked", "detail": "risky", "rule": "recursive delete"}},
          {"tool": "send_message", "target": "Send", "status": "blocked",
           "receipt": {"kind": "held", "detail": "ask_first", "ask": "send"}}]}]}
        """#.utf8))
        let actions = try #require(ConversationPost(wire: json)?.nightShift?.runs.first?.actions)
        #expect(actions[0].receipt == .init(kind: .blocked, detail: "risky", rule: "recursive delete"))
        #expect(actions[1].receipt == .init(kind: .held, detail: "ask_first", ask: "send"))
    }

    @Test func receiptsFromBeforeReasonsStillRead() throws {
        // The add-on's 1.0 shape: no rule, no hold kind.
        let json = try GatewayJSON.parse(Data(#"""
        {"id": "night-1", "kind": "night_shift", "at": 1792562400, "runs": [{"id": "cron:a:e", "actions": [
          {"tool": "terminal", "target": "git push", "status": "done",
           "receipt": {"kind": "always", "detail": "git push", "granted_at": 1791900000}}]}]}
        """#.utf8))
        let receipt = try #require(ConversationPost(wire: json)?.nightShift?.runs.first?.actions.first?.receipt)
        #expect(receipt == .init(kind: .always, detail: "git push", grantedAt: Date(timeIntervalSince1970: 1_791_900_000)))
        #expect(receipt.rule == nil && receipt.ask == nil)
    }

    @Test func postsCachedBeforeReasonsStillDecode() throws {
        // A post this device saved with 1.0's Codable shape: its receipts have no rule or ask keys.
        let post = nightShiftSample()
        let saved = try JSONEncoder().encode(post)
        var object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        func strip(_ value: Any) -> Any {
            if var dict = value as? [String: Any] {
                dict.removeValue(forKey: "rule")
                dict.removeValue(forKey: "ask")
                return dict.mapValues(strip)
            }
            if let list = value as? [Any] { return list.map(strip) }
            return value
        }
        object = strip(object) as! [String: Any]
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(!String(decoding: old, as: UTF8.self).contains("\"rule\""))
        let decoded = try JSONDecoder().decode(ConversationPost.self, from: old)
        #expect(decoded == post)
    }
}

@Suite struct PapertrailWhyTests {
    typealias Entry = Papertrail.Entry
    let at: (Date) -> String = { _ in "14:02" }

    func entry(_ why: Papertrail.Why?, provider: String? = "claude-subscription-direct", model: String? = "m", route: String = "online",
               input: Int = 18_000, output: Int = 900, searches: Int = 0, pages: Int = 0, images: Int = 0) -> Entry {
        var entry = Entry(id: "t-1", at: 1_760_969_000, route: route, provider: provider, model: model, services: ["exa"],
                          inputTokens: input, outputTokens: output, searches: searches, pages: pages, images: images)
        entry.why = why
        return entry
    }

    func reason(_ entry: Entry) -> String {
        let why = entry.why(bot: "Scout", time: at)
        plain(why.reason)
        if let sent = why.sent { plain(sent) }
        return why.reason
    }

    @Test func aChatSaysWhoWhereAndWhy() {
        #expect(reason(entry(.init(origin: "chat", messages: 24))) ==
                "Scout was answering you in a chat. Scout uses Claude plan, which runs online, so it went there to be answered.")
        #expect(reason(entry(.init(origin: "chat", platform: "telegram"))).hasPrefix("Scout was answering you on Telegram."))
        #expect(reason(entry(.init(origin: "chat", platform: "some-bridge"))).hasPrefix("Scout was answering you in a chat."))
    }

    @Test func scheduledAndBoardWorkNamesItsTask() {
        #expect(reason(entry(.init(origin: "schedule", task: "Morning brief"))).hasPrefix(
            "Scout was running your schedule \u{201C}Morning brief\u{201D}."))
        #expect(reason(entry(.init(origin: "schedule"))).hasPrefix("Scout was running one of your schedules."))
        #expect(reason(entry(.init(origin: "board", task: "Draft the report"))).hasPrefix(
            "Scout was working on the Board task \u{201C}Draft the report\u{201D}."))
        #expect(reason(entry(.init(origin: "helper"))).hasPrefix("A helper was working on one of Scout's schedules."))
    }

    @Test func theBackupYourNetworkAndSearchesEachSayWhyThere() {
        #expect(reason(entry(.init(origin: "chat", backup: true), provider: "openrouter")).hasSuffix(
            "Scout's main model didn't answer, so its backup, OpenRouter, took over."))
        #expect(reason(entry(.init(origin: "chat"), provider: "custom", route: "network")).hasSuffix(
            "Scout's model runs on another computer on your network, so it went there."))
        #expect(reason(entry(.init(origin: "chat"), provider: nil, model: nil, input: 0, output: 0, searches: 1)).hasSuffix(
            "Scout searched the web with Exa, which is online."))
    }

    @Test func thePersonsAnswersSayWhenAndToWhat() {
        let answers: [Papertrail.Why.Approval] = [.init(at: 1, choice: "once", ask: "send"), .init(at: 2, choice: "session"),
                                                  .init(at: 3, choice: "always", ask: "post"), .init(at: 4, choice: "deny", ask: "delete")]
        let text = reason(entry(.init(origin: "chat", approvals: answers)))
        // At most the last three are said.
        #expect(!text.contains("to sending"))
        #expect(text.contains("You said yes for the rest of the chat at 14:02."))
        #expect(text.contains("You chose Always for posting at 14:02."))
        #expect(text.contains("You said no to deleting at 14:02, so it wasn't done."))
        #expect(reason(entry(.init(origin: "chat", approvals: [.init(at: 1, choice: "once", ask: "send")]))).hasSuffix(
            "You said yes to sending at 14:02."))
        // The device, when it was recorded.
        #expect(reason(entry(.init(origin: "chat", approvals: [.init(at: 1, choice: "once", device: "iphone")]))).hasSuffix(
            "You said yes at 14:02 on your iPhone."))
        // An answer this build doesn't know is left out, never guessed.
        #expect(!reason(entry(.init(origin: "chat", approvals: [.init(at: 1, choice: "smart_approve")]))).contains("You"))
    }

    @Test func whatWentIsSizesAndKindsNeverWords() {
        var e = entry(.init(origin: "chat", messages: 24), searches: 2, pages: 3, images: 1)
        e.helpers = ["title_generation", "something_new"]
        e.localReads = ["calendar"]
        let sent = e.why(bot: "Scout", time: at).sent
        #expect(sent == "What went: 24 messages (about 19k tokens), 2 web searches, 3 web pages, 1 picture request "
                + "and a request to name the chat. It read your calendar on your Mac first.")
        #expect(entry(.init(origin: "chat", messages: 1), input: 0, output: 0).why(bot: "Scout", time: at).sent == "What went: 1 message.")
    }

    @Test func anEntryKeptBeforeReasonsSaysSoAndStillSaysWhatWent() {
        let old = entry(nil).why(bot: "Scout", time: at)
        #expect(old.reason == "Nollie didn't keep the reason for this one.")
        #expect(!old.kept)
        #expect(old.sent == "What went: about 19k tokens.")
        // An origin this build doesn't know is not a reason either.
        #expect(entry(.init(origin: "telepathy")).why(bot: "Scout", time: at).reason == PapertrailWhy.notKept)
    }

    @Test func reasonsDecodeAndOldEntriesStillDo() throws {
        let body = #"""
        {"entries": [
          {"id": "t-1", "at": 1760969000, "route": "online", "provider": "anthropic", "input_tokens": 10,
           "why": {"origin": "schedule", "task": "Morning brief", "platform": null, "messages": 6, "backup": false,
                   "approvals": [{"at": 1760968990, "choice": "once", "ask": "send"}]}},
          {"id": "t-0", "at": 1760960000, "route": "online", "provider": "anthropic", "input_tokens": 10}
        ]}
        """#
        let trail = try JSONCoding.decoder.decode(Papertrail.self, from: Data(body.utf8))
        let first = try #require(trail.entries?.first?.why)
        #expect(first.origin == "schedule" && first.task == "Morning brief" && first.messages == 6 && first.backup == false)
        #expect(first.approvals == [.init(at: 1_760_968_990, choice: "once", ask: "send")])
        #expect(trail.entries?.last?.why == nil)
    }
}

/// Pictures of "Why?" opened, drawn off screen on whichever platform runs the tests (the iPhone suite and the Mac
/// suite both run this), light and dark. Glass is off here: drawn from the views, Liquid Glass would come out blank.
@MainActor @Suite struct WhySnapshotTests {
    private static let snapshotDefaults: UserDefaults = {
        let d = UserDefaults(suiteName: "nollie.why-snapshots")!
        d.set(false, forKey: GlassAppearance.enabledKey)
        return d
    }()

    #if os(macOS)
    private static let platform = "mac"
    #else
    private static let platform = "iphone"
    #endif

    private func attach(_ view: some View, named name: String, width: CGFloat) {
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: view
                .padding(16)
                .frame(width: width)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme)
                .defaultAppStorage(Self.snapshotDefaults)
                .environment(AppModel.shared))
            renderer.scale = 2
            guard let image = renderer.uiImage, let data = image.pngData() else { Issue.record("no picture for \(name)"); continue }
            Attachment.record(data, named: "\(Self.platform)-\(name)-\(scheme == .dark ? "dark" : "light").png")
        }
    }

    @Test func theNightShiftCardWithWhyOpen() {
        let post = nightShiftSample()
        let night = post.nightShift!
        let open: Set<String> = [NightShiftWhy.key(run: "cron:244c3b0b8e42:e-80", index: 2),
                                 NightShiftWhy.key(run: "cron:export:e-41", index: 0),
                                 NightShiftWhy.key(run: "cron:export:e-41", index: 1)]
        attach(NightShiftCard(card: night, expanded: open) { _ in }, named: "why-night-shift", width: 440)
        attach(ConversationPostView(post: rehearsalSample(), expanded: [NightShiftWhy.key(run: "held", index: 0),
                                                                        NightShiftWhy.key(run: "looked", index: 0)]) { _ in },
               named: "why-rehearsal", width: 440)
    }

    @Test func papertrailRowsWithWhyOpen() {
        var chat = Papertrail.Entry(id: "t-1", at: Date().timeIntervalSince1970 - 600, provider: "anthropic", model: "m",
                                    services: ["exa"], inputTokens: 18_000, outputTokens: 900, searches: 2, pages: 3)
        chat.helpers = ["title_generation"]
        chat.why = .init(origin: "chat", messages: 24, approvals: [.init(at: Date().timeIntervalSince1970 - 640, choice: "once", ask: "send")])
        var backup = Papertrail.Entry(id: "t-2", at: Date().timeIntervalSince1970 - 3600, provider: "openrouter", model: "m",
                                      inputTokens: 6_400, outputTokens: 1_200)
        backup.why = .init(origin: "schedule", task: "Morning brief", messages: 6, backup: true)
        let old = Papertrail.Entry(id: "t-3", at: Date().timeIntervalSince1970 - 7200, provider: "anthropic", model: "m",
                                   inputTokens: 8_800, outputTokens: 900)
        attach(VStack(spacing: 14) {
            PapertrailRow(entry: chat, index: 0, today: true, bot: "Scout", open: true) {}
            PapertrailRow(entry: backup, index: 1, today: true, bot: "Scout", open: true) {}
            PapertrailRow(entry: old, index: 2, today: true, bot: "Scout", open: true) {}
            PapertrailRow(entry: old, index: 3, today: true, bot: "Scout", open: false) {}
        }, named: "why-papertrail", width: 520)
    }
}
