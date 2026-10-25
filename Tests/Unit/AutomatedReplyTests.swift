import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

@Suite struct AutomatedReplyTests {
    private let cron = "[Cronjob \"Board follow-through\" output]\nCheck the board."

    @Test func trustedKanbanDiagnosticSilenceDoesNotBecomeAUserBubble() throws {
        let prompt = "⏱ [default] @forager Kanban fixture-task timed out (max_runtime=0s); will retry"
        let value: JSONValue = .object(["role": "user", "content": .string(prompt), "display_metadata": .object(["notification_category": "diagnostic"])])
        let decoded = try value.decode(TranscriptMessage.self)
        #expect(decoded.notificationCategory == "diagnostic")
        let raw = [decoded, TranscriptMessage(role: "assistant", text: "[SILENT]", finishReason: "stop")]
        #expect(AutomatedReply.presentationItems(TranscriptItem.fromHistory(raw)).isEmpty)
        #expect(AutomatedReply.previewMessages(raw).isEmpty)
        let cached = try JSONDecoder().decode(TranscriptMessage.self, from: JSONEncoder().encode(decoded))
        #expect(cached.notificationCategory == "diagnostic")

        let literal = [TranscriptMessage(role: "user", text: prompt), raw[1]]
        #expect(AutomatedReply.presentationItems(TranscriptItem.fromHistory(literal)).count == 2, "identical text without trusted metadata remains a human message")
    }

    @Test(arguments: ["internal_notification", "async_delegation_complete", "process_complete"])
    func trustedMachineryKindsKeepUsefulAnswersAndFailures(_ kind: String) {
        let prompt = TranscriptMessage(role: "user", text: "A background task changed", displayKind: kind)
        let useful = [prompt, TranscriptMessage(role: "assistant", text: "The price has dropped.", finishReason: "stop")]
        let shown = AutomatedReply.presentationItems(TranscriptItem.fromHistory(useful))
        #expect(shown.count == 1)
        if case .assistant(let text, _, _) = shown.first?.kind { #expect(text == "The price has dropped.") }
        else { Issue.record("The useful assistant reply must remain visible") }
        let failed = [prompt, TranscriptMessage(role: "assistant", text: "[SILENT]", finishReason: "error")]
        #expect(AutomatedReply.presentationItems(TranscriptItem.fromHistory(failed)).count == 1)
        let quiet = [prompt, TranscriptMessage(role: "assistant", text: "NO_REPLY", finishReason: "stop")]
        #expect(AutomatedReply.presentationItems(TranscriptItem.fromHistory(quiet)).isEmpty)
    }

    @Test func trustedPromptDisappearsImmediatelyButToolFailuresAndHumanLiteralsRemain() {
        let text = "Check the background task"
        let prompt = TranscriptItem(id: "machine", kind: .user(text: text, attachments: []), displayKind: "internal_notification")
        let tool = TranscriptItem(id: "tool", kind: .tool(ToolActivity(id: "tool", name: "web_search", status: .running)))
        #expect(AutomatedReply.presentationItems([prompt, tool]).map(\.id) == ["tool"])
        let failure = TranscriptItem(id: "failure", kind: .error(text: "The task could not finish."))
        #expect(AutomatedReply.presentationItems([prompt, failure]).map(\.id) == ["failure"])
        let human = TranscriptItem(id: "human", kind: .user(text: text, attachments: []))
        #expect(AutomatedReply.presentationItems([human, failure]).map(\.id) == ["human", "failure"])
    }

    private func messages(_ text: String, finish: String? = "stop") -> [TranscriptMessage] {
        [TranscriptMessage(role: "user", text: "Check my report", timestamp: 10),
         TranscriptMessage(role: "assistant", text: "Your report is ready.", timestamp: 20),
         TranscriptMessage(role: "user", text: cron, timestamp: 30),
         TranscriptMessage(role: "assistant", text: text, timestamp: 40, finishReason: finish)]
    }

    @Test(arguments: ["[SILENT]", " \nNO_REPLY\t"])
    func aQuietTurnHidesItsHeaderAndKeepsThePreviousPreviewDate(_ marker: String) {
        let raw = messages(marker)
        let items = TranscriptItem.fromHistory(raw)
        #expect(AutomatedReply.presentationItems(items).count == 2)
        #expect(items.count == 4, "the raw transcript is retained")
        #expect(BotsHome.latestVisibleReply(in: raw)?.text == "Your report is ready.")
        #expect(BotsHome.latestVisibleReply(in: raw)?.timestamp == 20, "quiet work cannot advance the unread date")
        #expect(!BotsHome.midTurn(raw, now: Date(timeIntervalSince1970: 41)))
    }

    @Test(arguments: ["The marker [SILENT] is literal text.", "NO_REPLY means nothing was sent.", "[silent]", "[SILEN"])
    func meaningfulAndIncompleteTextRemainsVisible(_ text: String) {
        let raw = messages(text)
        #expect(AutomatedReply.presentationItems(TranscriptItem.fromHistory(raw)).count == 4)
        #expect(BotsHome.latestVisibleReply(in: raw)?.text == text)
    }

    @Test(arguments: ["[SILENT]", "NO_REPLY"])
    func userLiteralsAndOrdinaryRepliesAreNotControlMessages(_ text: String) {
        let raw = [TranscriptMessage(role: "user", text: text), TranscriptMessage(role: "assistant", text: text)]
        #expect(AutomatedReply.presentationItems(TranscriptItem.fromHistory(raw)).count == 2)
        #expect(BotsHome.latestVisibleReply(in: raw)?.text == text)
        #expect(!AutomatedReply.suppressesCompletion(text: text, status: "complete", error: nil, items: TranscriptItem.fromHistory(raw)))
    }

    @Test(arguments: ["error", "interrupted", "length"])
    func unsuccessfulRepliesRemainVisible(_ reason: String) {
        let raw = messages("[SILENT]", finish: reason)
        #expect(AutomatedReply.presentationItems(TranscriptItem.fromHistory(raw)).count == 4)
        #expect(BotsHome.latestVisibleReply(in: raw)?.text == "[SILENT]")
        #expect(!AutomatedReply.suppressesCompletion(text: "[SILENT]", status: "complete", error: nil, items: TranscriptItem.fromHistory(raw)))
    }

    @Test func errorsAndFailedStepsAreNotHiddenByTheFinalMarker() {
        var items = TranscriptItem.fromHistory(messages("[SILENT]"))
        items.insert(TranscriptItem(id: "failed", kind: .tool(ToolActivity(id: "failed", name: "terminal", status: .failed))), at: 3)
        #expect(AutomatedReply.presentationItems(items).count == 5)
        #expect(!AutomatedReply.suppressesCompletion(text: "[SILENT]", status: "complete", error: nil, items: items))
        items[3] = TranscriptItem(id: "error", kind: .error(text: "Connection failed"))
        #expect(AutomatedReply.presentationItems(items).count == 5)
        #expect(!AutomatedReply.suppressesCompletion(text: "[SILENT]", status: "complete", error: "Connection failed", items: items))
    }

    @Test func aFailedBackgroundReportStaysVisibleEvenWhenItsReplyIsQuiet() {
        let raw = [TranscriptMessage(role: "user", text: "[Background process failed with exit code 1]"),
                   TranscriptMessage(role: "assistant", text: "[SILENT]", finishReason: "stop")]
        #expect(AutomatedReply.presentationItems(TranscriptItem.fromHistory(raw)).count == 2)
    }

    @Test func controlTokenFragmentsDoNotFlashButARealContinuationAppears() {
        var items = TranscriptItem.fromHistory(messages("[SI"))
        items[3].kind = .assistant(text: "[SI", reasoning: nil, streaming: true)
        #expect(AutomatedReply.presentationItems(items).count == 3, "the running header remains")
        items[3].kind = .assistant(text: "[SILENT] is a control marker.", reasoning: nil, streaming: true)
        #expect(AutomatedReply.presentationItems(items).count == 4)
    }

    @Test func trustedHiddenResultsKeepTheirRawRowsWithoutAnOrphanHeader() {
        var raw = messages("[SILENT]")
        raw[2].text = "Run the scheduled check."
        raw[2].displayKind = "internal_notification"
        raw[2].notificationCategory = "diagnostic"
        raw[3].displayKind = "hidden"
        let items = TranscriptItem.fromHistory(raw)
        #expect(items.count == 4)
        #expect(AutomatedReply.presentationItems(items).count == 2)
        #expect(BotsHome.latestVisibleReply(in: raw)?.timestamp == 20)
        #expect(AutomatedReply.suppressesCompletion(text: "", status: "complete", error: nil, items: items))
        raw[3].displayKind = nil
        #expect(AutomatedReply.suppressesCompletion(text: "", status: "complete", error: nil, items: TranscriptItem.fromHistory(raw)), "a suppressed final event can follow a streamed marker before the next snapshot")
    }

    @Test func typedHiddenAliasesAreRecognizedWithoutBroadeningLegacyTextMatching() throws {
        let value: JSONValue = .object(["role": "assistant", "content": "*NO_REPLY*", "display_content": "", "display_kind": "hidden", "display_metadata": .object(["control_marker": "intentional_silence"])])
        let message = try value.decode(TranscriptMessage.self)
        #expect(message.text == "*NO_REPLY*")
        #expect(message.controlMarker == "intentional_silence")
        let raw = [TranscriptMessage(role: "user", text: "Check the scheduled task", displayKind: "internal_notification"), message]
        let items = TranscriptItem.fromHistory(raw)
        #expect(items.count == 2)
        #expect(AutomatedReply.presentationItems(items).isEmpty)
        #expect(AutomatedReply.previewMessages(raw).isEmpty)
        #expect(!AutomatedReply.isControlMarker("*NO_REPLY*"))
        let cached = try JSONDecoder().decode(TranscriptMessage.self, from: JSONEncoder().encode(message))
        #expect(cached.controlMarker == "intentional_silence")
    }

    @MainActor @Test func aTrustedEmptyLiveCompletionIsQuietBeforeItsHistoryArrives() throws {
        let connection = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let runtime = GatewayRuntime(connection: connection, store: ConnectionStore())
        let chat = ChatSession(runtime: runtime, storedID: UUID().uuidString, title: nil)
        let notifier = Notifications()
        runtime.cardNotifier = notifier
        defer {
            TranscriptCache.flush()
            if let url = TranscriptCache.url(connection: connection.id, storedID: chat.storedID) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        chat.items = [TranscriptItem(id: "prompt", kind: .user(text: "Check the scheduled task", attachments: []), displayKind: "internal_notification"),
                      TranscriptItem(id: "tool", kind: .tool(ToolActivity(id: "t", name: "read_file", status: .done)))]
        chat.handle(event: GatewayEvent(type: "message.complete", sessionID: "test", payload: .object(["text": "", "status": "complete", "intentional_silence": true])))
        #expect(notifier.finished == 0)
        #expect(chat.items.count == 2, "raw tool output and prompt remain available")
        #expect(AutomatedReply.presentationItems(chat.items).isEmpty)
        #expect(!AutomatedReply.suppressesCompletion(text: "", status: "error", error: "Failed", items: chat.items, intentionalSilence: true))
    }

    @Test func aNewHumanPromptCannotBeHiddenByAnOlderQuietCompletion() {
        var items = TranscriptItem.fromHistory(messages("[SILENT]"))
        items.append(TranscriptItem(id: "new", kind: .user(text: "NO_REPLY", attachments: [])))
        let marked = AutomatedReply.completingSilently(items)
        #expect(marked.last?.displayKind == nil)
        #expect(AutomatedReply.presentationItems(marked).last?.id == "new")
    }

    @Test func theLastReplySkipsQuietAutomation() {
        let items = TranscriptItem.fromHistory(messages("[SILENT]"))
        #expect(AutomatedReply.lastReply(in: items) == "Your report is ready.")
    }

    @Test func cacheRetainsControlRowsAndFailureMetadata() throws {
        let connection = UUID(), session = UUID().uuidString
        defer { if let url = TranscriptCache.url(connection: connection, storedID: session) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        var raw = messages("NO_REPLY", finish: "error")
        raw[2].displayKind = "internal_notification"
        raw[2].notificationCategory = "diagnostic"
        let items = TranscriptItem.fromHistory(raw)
        TranscriptCache.save(items, connection: connection, storedID: session)
        TranscriptCache.flush()
        let cached = try #require(TranscriptCache.load(connection: connection, storedID: session))
        #expect(cached.last?.text == "NO_REPLY")
        #expect(cached.last?.finishReason == "error")
        #expect(cached[2].displayKind == "internal_notification")
        #expect(cached[2].notificationCategory == "diagnostic")
        #expect(AutomatedReply.presentationItems(TranscriptItem.fromHistory(cached)).count == 3)
    }

    @MainActor @Test(arguments: ["[SILENT]", "NO_REPLY", "Your report is ready."])
    func completedQuietTurnsKeepHistoryWithoutAReplyNotification(_ text: String) throws {
        let connection = GatewayConnection(name: "unit", gateway: try GatewayURL.normalize("https://127.0.0.1:1"), authMode: .sessionToken)
        let runtime = GatewayRuntime(connection: connection, store: ConnectionStore())
        let chat = ChatSession(runtime: runtime, storedID: UUID().uuidString, title: nil)
        let notifier = Notifications()
        runtime.cardNotifier = notifier
        let heard = Heard(chat.storedID)
        defer {
            heard.stop()
            TranscriptCache.flush()
            if let url = TranscriptCache.url(connection: connection.id, storedID: chat.storedID) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        chat.items = [TranscriptItem(id: "prompt", kind: .user(text: cron, attachments: []))]
        chat.handle(event: GatewayEvent(type: "message.complete", sessionID: "test", payload: .object(["text": .string(text), "status": "complete"])))
        #expect(chat.items.count == 2)
        let quiet = AutomatedReply.isControlMarker(text)
        #expect(heard.count == (quiet ? 0 : 1))
        #expect(notifier.finished == (quiet ? 0 : 1))
        #expect(AutomatedReply.presentationItems(chat.items).count == (quiet ? 0 : 2))
    }

    @MainActor private final class Notifications: CardNotifying {
        var finished = 0
        func cardArrived(_ card: PendingCard, chat: ChatSession) {}
        func turnFinished(chat: ChatSession, error: String?) { finished += 1 }
    }

    @MainActor private final class Heard {
        var count = 0
        private var observer: NSObjectProtocol?
        init(_ storedID: String) {
            observer = NotificationCenter.default.addObserver(forName: .hermesReplyCompleted, object: nil, queue: nil) { [weak self] note in
                guard note.userInfo?["storedID"] as? String == storedID else { return }
                MainActor.assumeIsolated { self?.count += 1 }
            }
        }
        func stop() { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
