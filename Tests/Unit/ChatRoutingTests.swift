import Foundation
import Testing
@testable import NollieCore

@MainActor
private final class FakeChat: ChatIdentity {
    var storedID: String
    var runtimeID: String

    init(runtimeID: String, storedID: String) {
        self.storedID = storedID
        self.runtimeID = runtimeID
    }
}

/// Which chat an event or a lookup belongs to.
@MainActor @Suite struct ChatRoutingTests {
    @Test func aReconnectRenamesTheRouteWithoutLosingTheChat() {
        var registry = ChatRegistry<FakeChat>()
        let chat = FakeChat(runtimeID: "rt-1", storedID: "stored-A")
        registry.add(chat)
        #expect(registry.byRuntime("rt-1") === chat)
        chat.runtimeID = "rt-2"
        #expect(registry.byRuntime("rt-2") === chat)
        #expect(registry.byRuntime("rt-1") == nil)
        #expect(registry.byStored("stored-A") === chat)
    }

    @Test func aSecondChatForTheSameStoredSessionTakesTheFirstOnesPlace() {
        var registry = ChatRegistry<FakeChat>()
        let older = FakeChat(runtimeID: "rt-1", storedID: "S")
        let newer = FakeChat(runtimeID: "rt-9", storedID: "S")
        registry.add(older)
        registry.add(newer)
        #expect(registry.all.count == 1)
        #expect(registry.byStored("S") === newer)
        registry.remove(newer)
        #expect(registry.all.isEmpty)
    }
}

/// A chat resumes as its owning bot regardless of which bot is selected. Resuming as another bot
/// makes the gateway move that chat into the other bot's store.
@Suite struct ChatOwnerTests {
    @Test func aCallNamesItsOwnerOrNoBotAtAll() {
        let owned = GatewayRuntime.params(["session_id": "abc"], owner: "scout")
        #expect(owned["profile"]?.stringValue == "scout")
        #expect(owned["session_id"]?.stringValue == "abc")
        for none in [nil, ""] as [String?] {
            #expect(GatewayRuntime.params(["session_id": "abc"], owner: none)["profile"] == nil)
        }
    }

    @Test(arguments: [
        (["default", "scout", "mason"], "scout" as String?, ["scout", "default", "mason"]),
        (["default", "scout"], nil, ["default", "scout"]),
        (["default", "scout"], "retired", ["default", "scout"]),
    ])
    func theSelectedBotIsAskedFirstIfItStillExists(profiles: [String], selected: String?, order: [String]) {
        #expect(GatewayRuntime.lookupOrder(profiles: profiles, selected: selected) == order)
    }

    @Test(arguments: [
        ([("default", true), ("scout", false)], "scout" as String?),
        ([("default", false)], "default"),
        ([("default", true)], "default"),
        ([], nil),
    ] as [([(String, Bool)], String?)])
    func aLiveCopyBeatsTheArchivedOneAMoveLeftBehind(copies: [(String, Bool)], owner: String?) {
        #expect(GatewayRuntime.owner(among: copies) == owner)
    }
}
