#if os(macOS)
import CryptoKit
import Foundation
import Network

/// The live picture of a helper's computer for a linked phone, on `/nollie/live`. The door
/// answers the socket itself and never asks Hermes: it checks which chat is wanted, asks a
/// provider (the Mac app, through the helper) for a feed, and relays the provider's messages
/// as they are, dropping video rather than queueing it when the phone can't keep up.
extension LinkDoor {
    /// Opens a feed for one stream, or answers nil (after `sink.end`, or "unavailable").
    typealias LiveProvider = @Sendable (LinkDoorLiveRequest, LinkDoorLiveSink) async -> LinkDoorLiveFeed?
}

/// Which chat's computer a phone wants to watch, and which linked device asked.
struct LinkDoorLiveRequest: Equatable, Sendable {
    let profile: String
    let sessionID: String
    let deviceID: UUID
}

/// The provider's side of a stream: what it sends the phone, and how it ends one.
/// Safe from any thread; calls after the stream has ended do nothing.
final class LinkDoorLiveSink: @unchecked Sendable {
    private weak var session: LinkDoorLiveSession?
    private let queue: DispatchQueue

    fileprivate init(session: LinkDoorLiveSession, queue: DispatchQueue) {
        self.session = session
        self.queue = queue
    }

    /// One whole message for the phone: text (a JSON object) or one encoded video frame.
    func send(_ data: Data, isText: Bool, isKeyframe: Bool) {
        queue.async { [self] in session?.offer(data, isText: isText, isKeyframe: isKeyframe) }
    }

    /// Sends `{"type":"end","reason":...}` and closes the socket.
    func end(reason: String) {
        queue.async { [self] in session?.end(reason) }
    }
}

/// What the door gives back to the provider: the phone's own messages and the door's stats,
/// each a JSON object, and a close when the stream ends for any reason.
struct LinkDoorLiveFeed: Sendable {
    let control: @Sendable (Data) -> Void
    let close: @Sendable () -> Void

    init(control: @escaping @Sendable (Data) -> Void, close: @escaping @Sendable () -> Void) {
        self.control = control
        self.close = close
    }
}

enum LinkDoorLive {
    /// The largest message the phone may send, a video message, and a text message.
    static let phoneMessageLimit = 512
    static let videoLimit = 8 * 1024 * 1024
    static let textLimit = 4096
    static let endReasons: Set<String> = ["stopped", "gone", "refused", "busy", "unavailable"]
    static let keyframeRequest = Data(#"{"type":"keyframe"}"#.utf8)

    enum Upgrade: Equatable, Sendable {
        /// The 101 to write, and the stream it opens.
        case accept(head: Data, request: LinkDoorLiveRequest)
        /// A reply that refuses, then closes.
        case refuse(Data)
    }

    /// Exactly one `profile` and one `session_id`, each a plain identifier, and nothing else
    /// but the device's own `token`. The 101 agrees no extensions, so every frame is read as sent.
    static func upgrade(_ request: LinkDoorHTTP.Request, device: UUID) -> Upgrade {
        let items = request.queryItems
        let refused = Upgrade.refuse(LinkDoorHTTP.reply(400, "The request was refused."))
        guard request.isWebSocketUpgrade, items.allSatisfy({ ["profile", "session_id", "token"].contains($0.name) }),
              items.filter({ $0.name == "token" }).count <= 1, let key = request.value("sec-websocket-key") else { return refused }
        func one(_ name: String) -> String? {
            let values = items.filter { $0.name == name }
            guard values.count == 1, let value = values[0].value, isIdentifier(value) else { return nil }
            return value
        }
        guard let profile = one("profile"), let session = one("session_id") else { return refused }
        let head = LinkDoorHTTP.serializeResponse(status: 101, reason: "Switching Protocols", headers: [
            .init(name: "Upgrade", value: "websocket"),
            .init(name: "Connection", value: "Upgrade"),
            .init(name: "Sec-WebSocket-Accept", value: acceptValue(key)),
            .init(name: "Cache-Control", value: "no-store"),
        ])
        return .accept(head: head, request: LinkDoorLiveRequest(profile: profile, sessionID: session, deviceID: device))
    }

    /// RFC 6455: base64 of the SHA-1 of the key and the protocol's own GUID.
    static func acceptValue(_ key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    /// `[A-Za-z0-9][A-Za-z0-9_.-]{0,159}`, as the preview checks them.
    static func isIdentifier(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        func plain(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
        guard let first = bytes.first, plain(first), bytes.count <= 160 else { return false }
        return bytes.dropFirst().allSatisfy { plain($0) || $0 == 95 || $0 == 46 || $0 == 45 }
    }

    /// The type of a message from the phone: a JSON object asking for a keyframe or reporting
    /// what it showed. Anything else is nil, and closes the stream.
    static func phoneMessageType(_ text: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: text) as? [String: Any],
              let type = object["type"] as? String, type == "keyframe" || type == "report" else { return nil }
        return type
    }

    static func endMessage(_ reason: String) -> Data {
        Data(#"{"type":"end","reason":"\#(endReasons.contains(reason) ? reason : "unavailable")"}"#.utf8)
    }

    /// Normal for a stream that finished, policy for one refused, try again later otherwise.
    static func closeCode(_ reason: String) -> UInt16 {
        switch reason {
        case "stopped", "gone": 1000
        case "refused": 1008
        default: 1013
        }
    }
}

/// What may go to the phone next. Video never queues: one message is with the connection at a
/// time, and the newest keyframe replaces one waiting. A frame that follows a dropped one can't
/// be shown, so after a drop every frame up to the next keyframe is withheld and the provider is
/// asked for one keyframe. Text is never dropped, but only so much may be waiting.
struct LinkDoorLiveGate: Sendable {
    static let textLimit = 32

    enum Decision: Equatable, Sendable {
        /// Hand it to the connection now.
        case send(Data)
        /// It waits for the video message with the connection.
        case held
        /// Dropped: the phone could not have shown it.
        case withheld
        /// Too much text the phone has not taken: the stream has stalled.
        case overflow
    }

    /// One second of sending, for the provider's judge. `taken` counts bytes the connection
    /// accepted; `waiting` the bytes still with it or held, at the end of the second.
    struct Second: Equatable, Sendable {
        var sent = 0
        var withheld = 0
        var taken = 0
        var waiting = 0
        var heard = false

        var json: Data {
            Data(#"{"type":"stats","sent":\#(sent),"withheld":\#(withheld),"taken":\#(taken),"waiting":\#(waiting),"heard":\#(heard)}"#.utf8)
        }
    }

    private var videoInFlight: Int?
    private var waiting: (data: Data, keyframe: Bool)?
    private var textsInFlight: [Int] = []
    private var needsKeyframe = false
    private var keyframeWanted = false
    private var current = Second()

    var inFlight: Bool { videoInFlight != nil }

    mutating func video(_ data: Data, keyframe: Bool) -> Decision {
        if keyframe {
            needsKeyframe = false
            keyframeWanted = false
        } else if needsKeyframe {
            return withhold()
        }
        guard videoInFlight != nil else {
            videoInFlight = data.count
            current.sent += 1
            return .send(data)
        }
        if waiting != nil {
            // A delta needs the frame before it, so only a keyframe may take a waiting frame's place.
            guard keyframe else { return withhold() }
            current.withheld += 1
        }
        waiting = (data, keyframe)
        return .held
    }

    /// The connection took the video message in flight; the next one to send, if one waited.
    mutating func videoTaken() -> Data? {
        if let bytes = videoInFlight { current.taken += bytes }
        videoInFlight = nil
        guard let next = waiting else { return nil }
        waiting = nil
        videoInFlight = next.data.count
        current.sent += 1
        return next.data
    }

    mutating func text(_ data: Data) -> Decision {
        guard textsInFlight.count < Self.textLimit else { return .overflow }
        textsInFlight.append(data.count)
        return .send(data)
    }

    /// The connection took the oldest text message; they are taken in order.
    mutating func textTaken() {
        guard !textsInFlight.isEmpty else { return }
        current.taken += textsInFlight.removeFirst()
    }

    /// True once after a drop, until a keyframe comes.
    mutating func takeKeyframeRequest() -> Bool {
        defer { keyframeWanted = false }
        return keyframeWanted
    }

    /// Ends the second: its counts, and what is still waiting now.
    mutating func second(heard: Bool) -> Second {
        var out = current
        out.heard = heard
        out.waiting = (videoInFlight ?? 0) + (waiting?.data.count ?? 0) + textsInFlight.reduce(0, +)
        current = Second()
        return out
    }

    private mutating func withhold() -> Decision {
        current.withheld += 1
        if !needsKeyframe {
            needsKeyframe = true
            keyframeWanted = true
        }
        return .withheld
    }
}

/// One live stream on a connection the door has already authenticated. Lives on the door's
/// queue; the owning session closes it on Remove, on door stop, and when the connection goes.
final class LinkDoorLiveSession: @unchecked Sendable {
    private let client: NWConnection
    private let queue: DispatchQueue
    private let request: LinkDoorLiveRequest
    private let provider: LinkDoor.LiveProvider?
    /// Asks the owner to close the connection.
    private let finished: @Sendable () -> Void
    private var reader = LinkDoorWebSocket.ClientReader(maximumMessage: LinkDoorLive.phoneMessageLimit)
    private var gate = LinkDoorLiveGate()
    private var feed: LinkDoorLiveFeed?
    /// What came for the feed before it opened: the latest keyframe request and report.
    private var earlyKeyframe: Data?
    private var earlyReport: Data?
    /// A report from the phone arrived this second.
    private var heard = false
    /// The door's close frame is on its way; nothing more is sent or relayed.
    private var ending = false
    private var stopped = false

    init(client: NWConnection, queue: DispatchQueue, request: LinkDoorLiveRequest, provider: LinkDoor.LiveProvider?,
         finished: @escaping @Sendable () -> Void) {
        self.client = client
        self.queue = queue
        self.request = request
        self.provider = provider
        self.finished = finished
    }

    /// Writes the 101, then reads the phone, counts each second and asks for a feed.
    func start(_ head: Data) {
        client.send(content: head, completion: .contentProcessed { [weak self] error in
            guard let self, !self.stopped else { return }
            guard error == nil else { self.finished(); return }
            self.readPhone()
            self.scheduleSecond()
            self.openFeed()
        })
    }

    /// From the owner, once: the feed is closed and nothing more is sent.
    func stop() {
        guard !stopped else { return }
        stopped = true
        closeFeed()
    }

    private func openFeed() {
        guard let provider else { end("unavailable"); return }
        let sink = LinkDoorLiveSink(session: self, queue: queue)
        let request = self.request
        Task { [weak self] in
            let opened = await provider(request, sink)
            guard let self else { opened?.close(); return }
            self.queue.async {
                guard !self.stopped, !self.ending else { opened?.close(); return }
                guard let opened else { self.end("unavailable"); return }
                self.feed = opened
                // A provider may send before it answers, so a keyframe asked for meanwhile still counts.
                for early in [self.earlyKeyframe, self.earlyReport].compactMap({ $0 }) { opened.control(early) }
                self.earlyKeyframe = nil
                self.earlyReport = nil
            }
        }
    }

    private func closeFeed() {
        let open = feed
        feed = nil
        earlyKeyframe = nil
        earlyReport = nil
        open?.close()
    }

    /// Hands a keyframe request or report to the feed, or keeps the latest until it opens.
    private func control(_ message: Data, type: String) {
        if let feed { feed.control(message); return }
        if type == "keyframe" { earlyKeyframe = message } else { earlyReport = message }
    }

    // MARK: Door to phone

    fileprivate func offer(_ data: Data, isText: Bool, isKeyframe: Bool) {
        guard !stopped, !ending else { return }
        if isText {
            guard data.count <= LinkDoorLive.textLimit, String(data: data, encoding: .utf8) != nil else { return }
            switch gate.text(LinkDoorWebSocket.frame(opcode: 1, payload: data, masked: false)) {
            case .send(let frame): write(frame, video: false)
            case .overflow: close(1013)
            default: break
            }
        } else {
            guard !data.isEmpty, data.count <= LinkDoorLive.videoLimit else { return }
            if case .send(let frame) = gate.video(LinkDoorWebSocket.frame(opcode: 2, payload: data, masked: false), keyframe: isKeyframe) {
                write(frame, video: true)
            }
            if gate.takeKeyframeRequest() { control(LinkDoorLive.keyframeRequest, type: "keyframe") }
        }
    }

    private func write(_ frame: Data, video: Bool) {
        client.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self, !self.stopped else { return }
            guard error == nil else { self.finished(); return }
            if video {
                if let next = self.gate.videoTaken(), !self.ending { self.write(next, video: true) }
            } else {
                self.gate.textTaken()
            }
        })
    }

    /// Tells the phone why, then closes.
    fileprivate func end(_ reason: String) {
        guard !stopped, !ending else { return }
        client.send(content: LinkDoorWebSocket.frame(opcode: 1, payload: LinkDoorLive.endMessage(reason), masked: false),
                    completion: .contentProcessed { _ in })
        close(LinkDoorLive.closeCode(reason))
    }

    private func close(_ code: UInt16) {
        guard !stopped, !ending else { return }
        ending = true
        closeFeed()
        client.send(content: LinkDoorWebSocket.message(.close(LinkDoorWebSocket.closePayload(code)), masked: false),
                    completion: .contentProcessed { [weak self] _ in self?.finished() })
    }

    /// Once a second, the gate's counts go to the provider's judge.
    private func scheduleSecond() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.stopped, !self.ending else { return }
            let second = self.gate.second(heard: self.heard)
            self.heard = false
            self.feed?.control(second.json)
            self.scheduleSecond()
        }
    }

    // MARK: Phone to door

    /// Read strictly: small text asking for a keyframe or reporting, and control frames.
    /// Binary closes 1003; anything else, or anything too big, 1008.
    private func readPhone() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            let messages: [LinkDoorWebSocket.Message]
            do throws(LinkDoorWebSocket.Failure) {
                messages = try self.reader.feed(data ?? Data())
            } catch {
                self.close(error == .tooLarge ? 1008 : error.closeCode)
                return
            }
            for message in messages {
                switch message {
                case .text(let text):
                    guard let type = LinkDoorLive.phoneMessageType(text) else { self.close(1008); return }
                    guard !self.ending else { continue }
                    if type == "report" { self.heard = true }
                    self.control(text, type: type)
                case .binary:
                    self.close(1003)
                    return
                case .ping(let payload):
                    guard !self.ending else { continue }
                    self.client.send(content: LinkDoorWebSocket.message(.pong(payload), masked: false), completion: .contentProcessed { _ in })
                case .pong:
                    continue
                case .close(let payload):
                    // The phone is leaving: answer with its code, unless the door already said goodbye.
                    if self.ending { self.finished(); return }
                    self.ending = true
                    self.closeFeed()
                    let code = payload.count >= 2 ? Data(payload.prefix(2)) : Data()
                    self.client.send(content: LinkDoorWebSocket.message(.close(code), masked: false),
                                     completion: .contentProcessed { [weak self] _ in self?.finished() })
                    return
                }
            }
            if complete || error != nil { self.finished(); return }
            self.readPhone()
        }
    }
}
#endif
