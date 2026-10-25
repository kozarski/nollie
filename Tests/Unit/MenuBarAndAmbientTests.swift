#if os(macOS)
import AppKit
import Foundation
import Testing
import NollieCore
@testable import Nollie

/// Mac behaviour: the bots animate only while there is work in progress, and the menu bar item
/// has its own mark for each state.
@MainActor @Suite(.serialized) struct MenuBarAndAmbientTests {
    private func turn(_ id: String, detail: String, attention: Bool) -> TurnBoard.Turn {
        TurnBoard.Turn(id: id, title: "Chat", bot: "Bot", profile: "default", detail: detail, attention: attention, startedAt: Date())
    }

    @Test func theBotsMoveWhileTheBoardHoldsATurn() {
        let board = TurnBoard.shared, ambient = BotAmbient.shared
        let id = "ambient-\(UUID().uuidString)"
        defer { board.remove(id) }
        func inStep() -> Bool { ambient.anyWorking == !board.turns.isEmpty }
        board.remove(id)
        #expect(inStep())

        board.upsert(turn(id, detail: "Thinking…", attention: false))
        #expect([ambient.anyWorking, ambient.decorativeActive] == [true, true])

        // Waiting for an answer is still being mid-turn.
        board.upsert(turn(id, detail: "Needs you", attention: true))
        #expect(ambient.anyWorking)

        board.remove(id)
        #expect(inStep())
    }

    @Test func theMenuBarMarkIsATemplateAndDiffersForEveryState() throws {
        #expect(NSImage(named: CharacterDrawing.glyphName(.main)) != nil)
        let states: [MenuBarIcon.Badge] = [.idle, .working, .needsYou, .usingMac]
        var pictures = Set<Data>()
        for state in states {
            let image = MenuBarIcon.image(state)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
            let bitmap = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            pictures.insert(try #require(NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:])))
        }
        #expect(pictures.count == states.count)
    }
}
#endif
