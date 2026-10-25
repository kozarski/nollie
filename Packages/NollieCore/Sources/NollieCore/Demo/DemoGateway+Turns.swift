import Foundation

// The demo's replies. A turn is a short script: the typing bubble, a step or two the app really
// shows, then the whole reply. Anything that sends, buys, posts or deletes waits for the
// person's yes, as Ask first does.

extension DemoGateway {

    // MARK: Sending

    func submit(_ params: JSONValue) throws -> JSONValue {
        let id = params["session_id"]?.stringValue ?? ""
        guard let live = lives[id], let _ = chat(live.stored) else { throw Fault(code: 4006, message: "unknown session") }
        let prompt = params["text"]?.stringValue ?? ""
        if live.running { return ["status": "queued"] }
        Task { await self.run(turn: prompt, in: id) }
        return ["status": "streaming"]
    }

    /// What kind of reply a message gets.
    enum Kind {
        case sendSomething
        case lookSomethingUp
        case plain
    }

    static func kind(of prompt: String) -> Kind {
        let words = Set(prompt.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init))
        if !words.isDisjoint(with: ["send", "email", "mail", "text", "post", "buy", "order", "pay", "delete"]) { return .sendSomething }
        let looking: Set<String> = ["find", "search", "compare", "price", "cheap", "cheaper", "best", "look", "weekend", "research", "watch", "shortlist"]
        if !words.isDisjoint(with: looking) { return .lookSomethingUp }
        return .plain
    }

    /// The person's own words, shortened so a reply can hand them back.
    static func excerpt(_ prompt: String) -> String {
        let one = clean(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        if one.count <= 56 { return one }
        let cut = one.prefix(56)
        let tidy = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return tidy + "..."
    }

    func run(turn prompt: String, in id: String) async {
        guard var live = lives[id], !closed else { return }
        live.running = true
        live.turnStartedAt = Date().timeIntervalSince1970
        live.inflight = ["user": .string(prompt), "assistant": "", "streaming": true]
        lives[id] = live
        replies += 1

        emit(live, "message.start")
        // The typing bubble, for a moment, as a real model takes before its first word.
        await pause(1.6)

        var steps: [DemoSeed.Row] = []
        var text = ""
        let kind = Self.kind(of: prompt)
        switch kind {
        case .sendSomething:
            text = await sendTurn(id: id, prompt: prompt, steps: &steps)
        case .lookSomethingUp:
            await step(id, &steps, tool: "web_search", context: Self.excerpt(prompt), summary: "Did 1 search")
            await step(id, &steps, tool: "web_extract", context: "The top results", summary: "Read 2 pages")
            text = await speak(id, "Thanks. In your own Nollie I'd look into “\(Self.excerpt(prompt))” now and come back with what I find, with every step shown above. This is a demo, so here is a sample reply instead.")
        case .plain:
            let line = replies % 2 == 0
                ? "Got it. In your own Nollie I'd start on “\(Self.excerpt(prompt))” and tell you here when it's done."
                : "Noted. I'd keep working on “\(Self.excerpt(prompt))” in the background and message you here when there is something to see."
            text = await speak(id, line + "\n\nTry asking me to send something to see Ask first.")
        }
        await finish(id, prompt: prompt, steps: steps, text: text)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// Streams text a few words at a time.
    @discardableResult
    func speak(_ id: String, _ text: String) async -> String {
        guard let live = lives[id] else { return text }
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 14, limitedBy: text.endIndex) ?? text.endIndex
            let piece = String(text[index..<end])
            emit(live, "message.delta", ["text": .string(piece)])
            lives[id]?.outputTokens += max(1, piece.count / 4)
            index = end
            await pause(0.03)
        }
        return text
    }

    /// One tool step the app draws as a row: it starts, takes a moment, and is done.
    func step(_ id: String, _ steps: inout [DemoSeed.Row], tool: String, context: String, summary: String) async {
        guard let live = lives[id] else { return }
        let call = "t-" + UUID().uuidString.prefix(8).lowercased()
        emit(live, "tool.start", ["tool_id": .string(call), "name": .string(tool), "context": .string(context)])
        await pause(0.8)
        emit(live, "tool.complete", ["tool_id": .string(call), "name": .string(tool), "duration_s": 0.8, "summary": .string(summary)])
        steps.append(DemoSeed.Row(id: 0, role: "tool", text: summary, at: Date().timeIntervalSince1970, name: tool, context: context))
    }

    /// Files the turn in the chat and tells the app it is over.
    func finish(_ id: String, prompt: String, steps: [DemoSeed.Row], text: String) async {
        guard var live = lives[id], let at = chatIndex(live.stored) else { return }
        let now = Date().timeIntervalSince1970
        var rows = chats[at].rows
        rows.append(DemoSeed.Row(id: rows.count + 1, role: "user", text: prompt, at: live.turnStartedAt))
        for var row in steps {
            row.id = rows.count + 1
            rows.append(row)
        }
        rows.append(DemoSeed.Row(id: rows.count + 1, role: "assistant", text: text, at: now))
        chats[at].rows = rows
        chats[at].lastActive = now
        if chats[at].title == "New chat" {
            chats[at].title = Self.excerpt(prompt)
            emit(live, "session.title", ["session_id": .string(live.stored), "title": .string(chats[at].title)])
        }
        live.running = false
        live.inflight = nil
        lives[id] = live
        let report = Self.usage(output: live.outputTokens)
        emit(live, "session.usage", ["usage": report])
        emit(live, "message.complete", ["text": .string(text), "status": "complete", "usage": report])
        broadcastChanged()
    }

    /// Tells sockets that are not on the chat that the list changed, so rows and previews refresh.
    private func broadcastChanged() {
        let text = Self.event("sessions.changed", session: "", payload: nil)
        for channel in channels.values { channel.push(text) }
    }

    // MARK: Ask first

    /// A turn that sends something: the step is held until the person says yes.
    private func sendTurn(id: String, prompt: String, steps: inout [DemoSeed.Row]) async -> String {
        var text = await speak(id, "I'll do that. This one waits for your yes first.")
        guard let live = lives[id] else { return text }
        let call = "askfirst-" + UUID().uuidString.prefix(8).lowercased()
        emit(live, "tool.start", ["tool_id": .string(call), "name": "computer_use", "context": "Press Send in Mail"])
        let choice = await ask(id, description: "Press “Send” in Mail.\nYou're about to press “Send”.")
        let reply: String
        if choice == "deny" {
            reply = "\n\nOkay, I didn't send it."
        } else {
            emit(live, "tool.complete", ["tool_id": .string(call), "name": "computer_use", "duration_s": 1.0, "summary": "Used the computer"])
            steps.append(DemoSeed.Row(id: 0, role: "tool", text: "Used the computer", at: Date().timeIntervalSince1970,
                                      name: "computer_use", context: "Press Send in Mail"))
            reply = "\n\nSent."
        }
        text += await speak(id, reply)
        return text
    }

    /// Puts an Ask first card in front of the person and waits for the answer.
    func ask(_ id: String, description: String) async -> String {
        guard let request = openAsk(id, description: description) else { return "deny" }
        return await answer(to: request)
    }

    /// Raises the card: the question is open from this moment, for whoever opens the chat.
    func openAsk(_ id: String, description: String) -> String? {
        guard !closed, let live = lives[id] else { return nil }
        let requestID = "srq-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let rule = "plugin_rule:nollie-ask-first:send:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let params: JSONValue = [
            "session_id": .string(live.id), "request_id": .string("req-" + UUID().uuidString.prefix(8).lowercased()),
            "command": "<computer_use> (plugin approval rule)", "description": .string(description),
            "pattern_key": .string(rule), "pattern_keys": [.string(rule)], "tool_name": "computer_use",
            "choices": ["once", "deny"], "allow_session": false, "allow_permanent": false,
        ]
        let frame: JSONValue = ["jsonrpc": "2.0", "id": .string(requestID), "method": "approval", "params": params]
        lives[id]?.openFrames[requestID] = frame
        let text = Self.encode(frame)
        for key in live.members { channels[key]?.push(text) }
        return requestID
    }

    func answer(to request: String) async -> String {
        await withCheckedContinuation { waiters[request] = $0 }
    }

    /// Mason is waiting on a yes when the demo opens. The turn is already under way: the note is
    /// written and Mail is ready, so the card is there the first time Mason's chat is opened.
    func seedAskIfNeeded() async {
        guard !seededAsk, let at = chatIndex("demo-mason-main") else { return }
        seededAsk = true
        let stored = chats[at].id
        let id = String(UUID().uuidString.prefix(8).lowercased())
        var live = Live(id: id, stored: stored, profile: "mason")
        live.running = true
        live.turnStartedAt = Date().timeIntervalSince1970 - 60
        live.inflight = ["user": "Can you email Sam to say I can meet at 10 on Thursday?",
                         "assistant": .string("Sure. Here is the note I'll send from Mail:\n\n“\(DemoSeed.heldNote)”\n\nI'll wait for your yes first."),
                         "streaming": true]
        lives[id] = live
        let request = openAsk(id, description: "Email Sam: “\(DemoSeed.heldNote)”\nPress “Send” in Mail.\nYou're about to press “Send”.")
        Task { await self.finishHeldNote(id, request: request) }
    }

    private func finishHeldNote(_ id: String, request: String?) async {
        guard let request else { return }
        let choice = await answer(to: request)
        guard let live = lives[id], !closed else { return }
        var steps: [DemoSeed.Row] = []
        let note = "Sure. Here is the note I'll send from Mail:\n\n“\(DemoSeed.heldNote)”\n\nI'll wait for your yes first."
        var text = note
        if choice == "deny" {
            text += await speak(id, "\n\nOkay, I didn't send it.")
        } else {
            let call = "askfirst-" + UUID().uuidString.prefix(8).lowercased()
            emit(live, "tool.start", ["tool_id": .string(call), "name": "computer_use", "context": "Press Send in Mail"])
            await pause(0.8)
            emit(live, "tool.complete", ["tool_id": .string(call), "name": "computer_use", "duration_s": 0.8, "summary": "Used the computer"])
            steps.append(DemoSeed.Row(id: 0, role: "tool", text: "Used the computer", at: Date().timeIntervalSince1970,
                                      name: "computer_use", context: "Press Send in Mail"))
            text += await speak(id, "\n\nSent.")
        }
        await finish(id, prompt: "Can you email Sam to say I can meet at 10 on Thursday?", steps: steps, text: text)
    }
}
