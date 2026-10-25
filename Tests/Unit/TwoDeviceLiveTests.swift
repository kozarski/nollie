import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// Two connections to one gateway standing in for two devices (a Mac and a phone) with the same
/// chat open. These need the session shared between clients the way the real gateway shares it,
/// which the mock does.
extension LiveGatewayTests {
    @Suite struct TwoDevices {
        private func recentChatID(on runtime: GatewayRuntime) async throws -> String {
            let query = [("order", "recent"), ("limit", "5")].map { URLQueryItem(name: $0.0, value: $0.1) }
            let page: SessionListResponse = try await runtime.api.get("/api/sessions", query: query, profile: runtime.selectedProfile)
            return try #require(page.sessions.first?.id)
        }

        /// Two runtimes on one gateway, started, with the same chat opened on both.
        @MainActor private func openOnBoth(_ target: (url: String, token: String), named name: String)
            async throws -> (store: ConnectionStore, connection: GatewayConnection, first: GatewayRuntime, second: GatewayRuntime, a: ChatSession, b: ChatSession, stored: String) {
            let store = ConnectionStore()
            let (connection, first) = try LiveGatewayTests.connect(target, named: name, store: store)
            let second = GatewayRuntime(connection: connection, store: store)
            await first.start()
            await second.start()
            let stored = try await recentChatID(on: first)
            let a = try await first.openChat(storedID: stored, title: nil, waitForResume: true)
            let b = try await second.openChat(storedID: stored, title: nil, waitForResume: true)
            return (store, connection, first, second, a, b, stored)
        }

        /// When one device sends a prompt, the second device shows it too, along with the reply. The
        /// gateway pushes a chat's events to every attached device, but they hold only the reply, so
        /// the observing device looks up the prompt as the turn begins.
        @MainActor @Test func aTurnSentFromOneDeviceAppearsOnTheOther() async throws {
            guard let target = LiveGatewayTests.tokenTarget else { return }
            let rig = try await openOnBoth(target, named: "live two devices")
            defer { rig.store.delete(id: rig.connection.id) }
            #expect(rig.a.runtimeID == rig.b.runtimeID, "the two clients are not on the same live session")

            func promptsShown(_ chat: ChatSession) -> [String] {
                var found: [String] = []
                for item in chat.items {
                    if case .user(let text, _) = item.kind { found.append(text) }
                }
                return found
            }
            func repliesShown(_ chat: ChatSession) -> Int {
                var finished = 0
                for item in chat.items {
                    guard case .assistant(let text, _, let streaming) = item.kind else { continue }
                    if !streaming && !text.isEmpty { finished += 1 }
                }
                return finished
            }
            let baseline = (sender: repliesShown(rig.a), watcher: repliesShown(rig.b))
            let prompt = "Answer using one word only: pong \(UUID().uuidString.prefix(6))"
            _ = await rig.a.send(prompt)

            var watcherSawItRun = false
            let deadline = Date().addingTimeInterval(120)
            repeat {
                // The mock's scripted turn requests an approval, and either device can answer it.
                if let card = rig.a.cards.first(where: { $0.method == "approval" }) {
                    await rig.a.respond(card: card, result: ["choice": "once"])
                }
                watcherSawItRun = watcherSawItRun || rig.b.isRunning
                let quiet = !(rig.a.isRunning || rig.b.isRunning)
                let bothReplied = repliesShown(rig.a) > baseline.sender && repliesShown(rig.b) > baseline.watcher
                if quiet && bothReplied { break }
                try await Task.sleep(for: .milliseconds(250))
            } while Date() < deadline
            print("two devices: \(rig.a.items.count) items on the sender, \(rig.b.items.count) on the watcher, turn seen running there: \(watcherSawItRun)")
            #expect(repliesShown(rig.a) > baseline.sender, "no reply reached the sending device")
            #expect(watcherSawItRun, "the watching device never showed the turn running")
            #expect(repliesShown(rig.b) > baseline.watcher, "the reply never showed on the watching device")
            #expect(promptsShown(rig.b).filter { $0 == prompt }.count == 1, "the watcher should show the other device's prompt exactly once")
            #expect(!rig.b.isRunning)

            await rig.first.stop()
            await rig.second.stop()
        }

        /// Both devices show an approval card. One answers it; nothing used to tell the other, so
        /// its card stayed for good. Now it goes once the gateway stops listing the approval as waiting.
        @MainActor @Test func anApprovalAnsweredOnOneDeviceClearsFromTheOther() async throws {
            guard let target = LiveGatewayTests.mockTarget else { return }
            let rig = try await openOnBoth(target, named: "live approval")
            defer { rig.store.delete(id: rig.connection.id) }

            _ = await rig.a.send("Tidy the mail server \(UUID().uuidString.prefix(6))")
            func approvalCard(_ chat: ChatSession) -> PendingCard? { chat.cards.first { $0.method == "approval" } }
            var giveUp = Date().addingTimeInterval(60)
            while Date() < giveUp, approvalCard(rig.a) == nil || approvalCard(rig.b) == nil { try await Task.sleep(for: .milliseconds(100)) }
            let card = try #require(approvalCard(rig.a), "no approval reached the sending device")
            try #require(approvalCard(rig.b) != nil, "no approval reached the watching device")
            #expect(rig.second.needsAttention.contains(rig.stored))

            // Hold on until the card stops being "just arrived" on the observing device, then answer it.
            try await Task.sleep(for: .seconds(ChatSession.cardGrace + 0.5))
            await rig.a.respond(card: card, result: ["choice": "once"])

            var wentWhileRunning = false
            giveUp = Date().addingTimeInterval(60)
            while Date() < giveUp {
                if approvalCard(rig.b) == nil, rig.b.isRunning { wentWhileRunning = true }
                if !rig.a.isRunning, !rig.b.isRunning { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            print("approval: the watcher's card went while the turn was still running = \(wentWhileRunning)")
            func notes(_ chat: ChatSession) -> [String] {
                var lines: [String] = []
                for item in chat.items {
                    if case .system(let text, _) = item.kind { lines.append(text) }
                }
                return lines
            }
            #expect(rig.b.cards.isEmpty, "the card answered on the other device is still up")
            #expect(!rig.second.needsAttention.contains(rig.stored), "the watching device still flags the chat for attention")
            #expect(notes(rig.b).contains("Answered on another device"))
            #expect(!notes(rig.a).contains("Answered on another device"), "the device that answered should not be told someone else did")
            #expect(wentWhileRunning, "the card should disappear as the turn progresses, not only at the end")

            await rig.first.stop()
            await rig.second.stop()
        }
    }
}
