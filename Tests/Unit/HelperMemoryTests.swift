import Foundation
import Testing
@testable import Nollie
@testable import NollieCore

/// What a helper remembers: read from the Mac, newest first, changed one entry at a time, forgotten with
/// a few seconds of Undo, never written over a change Hermes made meanwhile, and never read for Moss.
@MainActor
@Suite struct HelperMemoryTests {
    /// The add-on as the app sees it: two lists, and every change answered with the lists as they are now.
    @MainActor final class Mac {
        var memory: HelperMemory
        var calls: [String] = []
        var failNext: Error?

        init(_ memory: HelperMemory = HelperMemory(bot: "career", user: ["Name is Alex", "Likes tea", "Has a dog"],
                                                   memory: ["Shop on Sundays"])) {
            self.memory = memory
        }

        func texts(_ kind: HelperMemoryKind = .user) -> [String] { memory.list(kind).entries.map(\.text) }

        private func change(_ kind: HelperMemoryKind, _ step: (inout [String]) throws -> Void) throws -> HelperMemory {
            if let failNext { self.failNext = nil; throw failNext }
            var items = texts(kind)
            try step(&items)
            memory.stores[kind.rawValue] = HelperMemoryList(entries: items.map { HelperMemoryEntry(text: $0) }, used: 0, limit: 1375)
            return memory
        }

        /// Hermes changing an entry by itself, as its memory tool does.
        func hermesEdits(_ old: String, to new: String) {
            _ = try? change(.user) { items in items = items.map { $0 == old ? new : $0 } }
        }

        var door: HelperMemoryModel.Door {
            HelperMemoryModel.Door(
                load: { [self] in
                    calls.append("load")
                    if let failNext { self.failNext = nil; throw failNext }
                    return memory
                },
                add: { [self] text in
                    calls.append("add \(text)")
                    return try change(.user) { if !$0.contains(text) { $0.append(text) } }
                },
                edit: { [self] old, new, kind in
                    calls.append("edit \(old) -> \(new)")
                    return try change(kind) { items in
                        guard let at = items.firstIndex(of: old) else { throw HelperMemoryError.changed }
                        items[at] = new
                    }
                },
                forget: { [self] old, kind in
                    calls.append("forget \(old)")
                    return try change(kind) { $0.removeAll { $0 == old } }
                },
                setOn: { [self] on in
                    calls.append("on \(on)")
                    if let failNext { self.failNext = nil; throw failNext }
                    memory.on = on
                    return memory
                })
        }
    }

    /// An Undo window that only ends when the test says so.
    final class Gate: @unchecked Sendable {
        private var opened = false
        func open() { opened = true }
        var wait: @Sendable (Duration) async throws -> Void {
            { [self] _ in
                while !opened {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        }
    }

    func loaded(_ mac: Mac, gate: Gate = Gate()) async -> HelperMemoryModel {
        let model = HelperMemoryModel(wait: gate.wait)
        await model.load(mac.door)
        return model
    }

    /// Lets the tasks the model started run until `done` holds.
    func settle(_ done: () -> Bool) async {
        for _ in 0..<400 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: Reading

    @Test func readsTheAddOnsAnswerNewestFirst() throws {
        let json = """
        {"bot":"career","on":false,"provider":"elsewhere","stores":{
          "user":{"entries":[{"id":"a1","text":"Name is Alex"},{"id":"b2","text":"Likes tea"}],"used":25,"limit":1375},
          "memory":{"entries":[],"used":0,"limit":2200}}}
        """
        let memory = try JSONCoding.decoder.decode(HelperMemory.self, from: Data(json.utf8))
        #expect(memory.list(.user).newestFirst.map(\.text) == ["Likes tea", "Name is Alex"])
        #expect(memory.list(.user).entries.first?.id == "a1")
        #expect(memory.list(.memory).limit == 2200)
        #expect(!memory.on && memory.provider == "elsewhere" && memory.count == 2 && !memory.isEmpty)
        let bare = try JSONCoding.decoder.decode(HelperMemory.self, from: Data(#"{"bot":"work"}"#.utf8))
        #expect(bare.isEmpty && bare.on)
    }

    @Test func showsWhatTheMacKeeps() async {
        let mac = Mac()
        let model = await loaded(mac)
        #expect(model.phase == .ready)
        #expect(model.rows(.user).map(\.text) == ["Has a dog", "Likes tea", "Name is Alex"])
        #expect(model.rows(.memory).map(\.text) == ["Shop on Sundays"])
        #expect(model.shownCount == 4 && !model.isEmpty)
        let empty = await loaded(Mac(HelperMemory(bot: "work")))
        #expect(empty.isEmpty)
    }

    @Test func anOlderAddOnOrAPrivateRefusalHidesItAndAFailureOffersAnotherTry() async {
        for refusal in [HelperMemoryError.unavailable, .privateBot] {
            let mac = Mac()
            mac.failNext = refusal
            let model = await loaded(mac)
            #expect(model.phase == .unavailable && model.memory == nil)
        }
        let mac = Mac()
        mac.failNext = HermesAPIError.transport("offline")
        let model = await loaded(mac)
        #expect(model.phase == .failed && model.problem != nil)
        await model.load(mac.door)
        #expect(model.phase == .ready && model.problem == nil)
    }

    // MARK: Changing

    @Test func addsAndEditsOneEntry() async {
        let mac = Mac()
        let model = await loaded(mac)
        var draft = HelperMemoryModel.Draft.new()
        #expect(!draft.canSave)
        draft.text = "  Walks at seven  "
        #expect(await model.save(draft) == .saved)
        #expect(mac.texts().last == "Walks at seven")
        #expect(model.rows(.user).first?.text == "Walks at seven")

        var edit = HelperMemoryModel.Draft.editing(HelperMemoryEntry(text: "Likes tea"), in: .user)
        #expect(!edit.canSave)
        edit.text = "Likes green tea"
        #expect(await model.save(edit) == .saved)
        #expect(mac.texts() == ["Name is Alex", "Likes green tea", "Has a dog", "Walks at seven"])
    }

    @Test func anEditHermesBeatKeepsTheWordsAndTheNextSaveKeepsThemToo() async {
        let mac = Mac()
        let model = await loaded(mac)
        var edit = HelperMemoryModel.Draft.editing(HelperMemoryEntry(text: "Has a dog"), in: .user)
        edit.text = "Has a dog called Biscuit"
        mac.hermesEdits("Has a dog", to: "Has two dogs")

        guard case .changed(let kept) = await model.save(edit) else { Issue.record("not refused"); return }
        // Nothing written over Hermes's change; the list was read again; the words are still there.
        #expect(mac.texts() == ["Name is Alex", "Likes tea", "Has two dogs"])
        #expect(model.rows(.user).first?.text == "Has two dogs")
        #expect(kept.text == "Has a dog called Biscuit" && kept.isNew && kept.id == edit.id)

        #expect(await model.save(kept) == .saved)
        #expect(mac.texts() == ["Name is Alex", "Likes tea", "Has two dogs", "Has a dog called Biscuit"])
    }

    @Test func aRefusalSaysWhyAndChangesNothing() async {
        let mac = Mac()
        let model = await loaded(mac)
        mac.failNext = HelperMemoryError.refused("Its memory is full. Forget something first.")
        var draft = HelperMemoryModel.Draft.new()
        draft.text = "One more thing"
        #expect(await model.save(draft) == .refused("Its memory is full. Forget something first."))
        mac.failNext = HermesAPIError.transport("offline")
        #expect(await model.save(draft) == .failed)
        #expect(mac.texts().count == 3)
    }

    // MARK: Forgetting

    @Test func forgetHidesAtOnceAndUndoSendsNothing() async {
        let mac = Mac()
        let gate = Gate()
        let model = await loaded(mac, gate: gate)
        model.forget(HelperMemoryEntry(text: "Likes tea"), in: .user)
        #expect(!model.rows(.user).map(\.text).contains("Likes tea"))
        #expect(model.rowsWithForgetting(.user).map(\.forgetting) == [false, true, false])
        model.undo()
        gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.rows(.user).map(\.text).contains("Likes tea"))
        #expect(!mac.calls.contains { $0.hasPrefix("forget") })
        #expect(mac.texts().contains("Likes tea"))
    }

    @Test func forgetIsSentWhenUndosTimeIsUp() async {
        let mac = Mac()
        let gate = Gate()
        let model = await loaded(mac, gate: gate)
        model.forget(HelperMemoryEntry(text: "Likes tea"), in: .user)
        #expect(mac.texts().contains("Likes tea"), "nothing is sent while Undo is offered")
        gate.open()
        await settle { !mac.texts().contains("Likes tea") && model.leaving.isEmpty }
        #expect(mac.calls.filter { $0.hasPrefix("forget") } == ["forget Likes tea"])
        #expect(model.forgetting == nil && !model.rows(.user).map(\.text).contains("Likes tea"))
    }

    @Test func closingTheTabOrForgettingAnotherSendsTheWaitingOne() async {
        let mac = Mac()
        let model = await loaded(mac)
        model.forget(HelperMemoryEntry(text: "Likes tea"), in: .user)
        model.forget(HelperMemoryEntry(text: "Has a dog"), in: .user)
        // The first is no longer undoable and stays hidden while it goes.
        #expect(model.forgetting?.entry.text == "Has a dog")
        #expect(model.rows(.user).map(\.text) == ["Name is Alex"])
        await settle { !mac.texts().contains("Likes tea") }
        await model.sendForget()
        #expect(mac.texts() == ["Name is Alex"])
        #expect(mac.calls.filter { $0.hasPrefix("forget") }.count == 2)
        #expect(model.forgetting == nil)
    }

    @Test func aForgetThatFailsComesBackWithAWord() async {
        let mac = Mac()
        let model = await loaded(mac)
        model.forget(HelperMemoryEntry(text: "Likes tea"), in: .user)
        mac.failNext = HermesAPIError.transport("offline")
        await model.sendForget()
        #expect(model.rows(.user).map(\.text).contains("Likes tea"))
        #expect(model.problem == "Couldn't forget that. Try again.")
    }

    @Test func theSwitchIsSavedOrPutBack() async {
        let mac = Mac()
        let model = await loaded(mac)
        await model.setOn(false)
        #expect(!model.isOn && !mac.memory.on)
        mac.failNext = HermesAPIError.transport("offline")
        await model.setOn(true)
        #expect(!model.isOn && model.problem != nil)
    }

    // MARK: Private bots

    @Test func mossIsNeverReadAndAPrivateBotOnlyOnItsMac() {
        for bot in ["moss", "private", "Moss", "moss-2", "private_notes", "my.private"] {
            #expect(HelperMemoryAccess.decide(bot: bot, isPrivate: false, onThisMac: true) == .hidden, "\(bot)")
        }
        #expect(HelperMemoryAccess.decide(bot: "career", isPrivate: true, onThisMac: false) == .hidden)
        #expect(HelperMemoryAccess.decide(bot: "career", isPrivate: true, onThisMac: true) == .shownOnThisMac)
        #expect(HelperMemoryAccess.decide(bot: "career", isPrivate: false, onThisMac: false) == .shown)
        #expect(HelperMemoryAccess.decide(bot: "mossy", isPrivate: false, onThisMac: false) == .shown)

        #expect(!ProfileTab.available(withChat: false, memory: false).contains(.memory))
        let tabs = ProfileTab.available(withChat: false)
        #expect(tabs.firstIndex(of: .memory) == tabs.firstIndex(of: .instructions).map { $0 + 1 }, "right after Instructions")
        #expect(ProfileTab.memory.title == "Memory")
    }

    @Test func onlyTheMacThatRunsHermesSaysSo() {
        let plain = GatewayRuntime.memoryQuery(bot: "career", onThisMac: false)
        #expect(plain == [URLQueryItem(name: "bot", value: "career")])
        let here = GatewayRuntime.memoryQuery(bot: "career", onThisMac: true)
        #expect(here.map(\.name) == ["bot", "on_this_mac"])
        #if os(iOS)
        #expect(!ProfileMemoryTab.isThisMac(nil))
        #endif
    }
}
