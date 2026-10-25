import Foundation
import CoreGraphics
import SwiftUI
import Testing
@testable import Nollie
@testable import NollieCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// The collection-view list on its own (UIKit on iPhone, AppKit on Mac) inside a throwaway window. It starts
// on the newest row, holds the top visible row steady when rows land above it, and stays pinned to the
// composer while a reply grows. See Docs/specs/conversation-ui.md.

@MainActor
@Suite struct ConversationListTests {
    private actor SilentLink: ConversationLink {
        func currentPhase() async -> GatewayPhase { .idle }
        func request(_ method: String, _ params: GatewayJSON, timeout: Duration?) async throws -> GatewayJSON { [:] }
        func answer(question id: String, method: String, result: GatewayJSON) async {}
        func decline(question id: String) async {}
        func watch(session: String, profile: String?) async {}
        func unwatch(session: String) async {}
    }

    private struct Host {
        let coordinator: ConversationList.Coordinator
        let follower: ConversationFollower
        #if os(iOS)
        let window: UIWindow
        #else
        let window: NSWindow
        #endif

        func layOut() {
            #if os(iOS)
            window.layoutIfNeeded()
            #else
            window.contentView?.layoutSubtreeIfNeeded()
            #endif
        }
    }

    private func host() -> Host {
        let engine = ConversationEngine(key: "list-test-\(UUID())", sessionId: "s", link: SilentLink(),
                                        history: MemoryConversationHistory(segments: [:]), store: MemoryConversationCacheStore())
        let follower = ConversationFollower()
        let coordinator = ConversationList.Coordinator(engine: engine, follower: follower, answer: { _, _ in })
        let view = coordinator.makeView()
        #if os(iOS)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        view.frame = controller.view.bounds
        controller.view.addSubview(view)
        window.isHidden = false
        coordinator.set(insets: UIEdgeInsets(top: 100, left: 0, bottom: 90, right: 0))
        #else
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        view.frame = window.contentView!.bounds
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        coordinator.set(insets: NSEdgeInsets(top: 60, left: 0, bottom: 90, right: 0))
        #endif
        let made = Host(coordinator: coordinator, follower: follower, window: window)
        made.layOut()
        return made
    }

    /// Rows of every shape the demo chat has, numbered.
    private func items(_ numbers: Range<Int>, longLast: Int = 0) -> [ConversationListItem] {
        let texts = ConversationDemoLineage.longReplies + ConversationDemoLineage.shortReplies + ConversationDemoLineage.codeReplies
        let rows = numbers.map { n -> ConversationRow in
            if n % 2 == 0 { return ConversationRow(id: "r\(n)", kind: .user(text: ConversationDemoLineage.asks[n % 7], delivery: .sent)) }
            var text = texts[n % texts.count]
            if n == numbers.upperBound - 1, longLast > 0 { text += String(repeating: " and more words", count: longLast) }
            return ConversationRow(id: "r\(n)", kind: .assistant(ConversationReply(text: text, ending: .complete)))
        }
        return ConversationListItem.make(transcript: rows, cards: [], activity: nil, atNewestEnd: true)
    }

    @Test func opensOnTheNewestRowAndKeepsItsPlaceWhenRowsArriveAbove() throws {
        let list = host()
        list.coordinator.update(items(100..<200))
        list.layOut()
        #expect(abs(list.coordinator.debugDistanceFromBottom) <= 1, "opens with the end on the composer")
        #expect(list.follower.isFollowing)

        // Up into history, then a page lands above.
        list.coordinator.debugPersonScrolls(by: 3_000)
        list.layOut()
        #expect(!list.follower.isFollowing)
        let top = try #require(list.coordinator.debugTopRow)
        let before = try #require(list.coordinator.debugTopOffset(of: top))
        list.coordinator.update(items(0..<200))
        list.layOut()
        let after = try #require(list.coordinator.debugTopOffset(of: top))
        #expect(abs(after - before) <= 1, "row \(top) moved from \(before) to \(after)")
        #expect(list.coordinator.debugTopRow == top)

        // And the window drops its newest rows (below the screen) to make room: still in place.
        let number = try #require(Int(top.dropFirst()))
        #expect(number < 190)
        list.coordinator.update(items(0..<(number + 10)))
        list.layOut()
        #expect(abs((list.coordinator.debugTopOffset(of: top) ?? .infinity) - before) <= 1)
    }

    @Test func aGrowingReplyKeepsTheEndOnTheComposerWhileFollowingAndStillWhileReading() throws {
        let list = host()
        list.coordinator.update(items(0..<60))
        list.layOut()
        for growth in stride(from: 10, through: 200, by: 30) {
            list.coordinator.update(items(0..<60, longLast: growth))
            list.layOut()
            #expect(abs(list.coordinator.debugDistanceFromBottom) <= 1, "the end left the composer at \(growth)")
        }
        list.coordinator.debugPersonScrolls(by: 600)
        list.layOut()
        let top = try #require(list.coordinator.debugTopRow)
        let before = try #require(list.coordinator.debugTopOffset(of: top))
        for growth in stride(from: 230, through: 400, by: 30) {
            list.coordinator.update(items(0..<60, longLast: growth))
            list.layOut()
            #expect(abs((list.coordinator.debugTopOffset(of: top) ?? .infinity) - before) <= 1, "what was read moved at \(growth)")
        }
        #expect(!list.follower.isFollowing)
    }

    /// Scrolling up into rows not measured yet: they measure themselves above the screen and what is on screen
    /// moves by exactly as far as the list was scrolled.
    @Test func rowsMeasuringAboveTheScreenDoNotMoveIt() throws {
        let list = host()
        list.coordinator.update(items(0..<300))
        list.layOut()
        list.coordinator.debugPersonScrolls(by: 400)
        list.layOut()
        var moves: [CGFloat] = []
        for _ in 0..<12 {
            let top = try #require(list.coordinator.debugTopRow)
            let before = try #require(list.coordinator.debugTopOffset(of: top))
            list.coordinator.debugPersonScrolls(by: 300)
            list.layOut()
            let after = try #require(list.coordinator.debugTopOffset(of: top))
            moves.append(after - before)
        }
        print("CONVERSATION-MEASURE moves while scrolling up over rows measuring themselves: \(moves)")
        for move in moves { #expect(abs(move - 300) <= 1, "moved \(moves)") }
    }

    #if os(iOS)
    /// Rows given before the list has a size (as SwiftUI does on the first pass) are measured once it has one, and
    /// every cell on screen is as tall as its row draws.
    @Test func rowsGivenBeforeTheListHasASizeAreDrawnAtTheirHeight() async throws {
        let engine = ConversationEngine(key: "list-test-\(UUID())", sessionId: "s", link: SilentLink(),
                                        history: MemoryConversationHistory(segments: [:]), store: MemoryConversationCacheStore())
        let follower = ConversationFollower()
        let coordinator = ConversationList.Coordinator(engine: engine, follower: follower, answer: { _, _ in })
        let view = coordinator.makeView()
        let rows = ConversationDemoLineage(rows: 600).segments.values.flatMap { $0 }.sorted { $0.address.rowId < $1.address.rowId }
            .filter(\.isShown).suffix(80).map { $0.row() }
        coordinator.update(ConversationListItem.make(transcript: Array(rows), cards: [], activity: nil, atNewestEnd: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let controller = UIViewController()
        window.rootViewController = controller
        view.frame = controller.view.bounds
        controller.view.addSubview(view)
        window.isHidden = false
        coordinator.set(insets: UIEdgeInsets(top: 100, left: 0, bottom: 90, right: 0))
        window.layoutIfNeeded()
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(30)); window.layoutIfNeeded() }
        #expect(abs(coordinator.debugDistanceFromBottom) <= 1)
        // Every row the list measured is as tall as a fresh measure of it says.
        let stack = coordinator.debugStack
        var checked = 0
        var wrong: [String] = []
        for id in stack.ids where stack.isMeasured(id) {
            guard let item = coordinator.debugItem(id) else { continue }
            let fresh = UIHostingController(rootView: AnyView(coordinator.debugContent(for: item)))
            let size = fresh.sizeThatFits(in: CGSize(width: 402, height: CGFloat.greatestFiniteMagnitude))
            if abs(size.height.rounded(.up) - stack.height(of: id)) > 1 { wrong.append("\(id) \(stack.height(of: id)) vs \(size.height)") }
            checked += 1
        }
        #expect(wrong.isEmpty, "rows measured wrong: \(wrong)")
        #expect(checked > 10)
    }
    #endif
}

