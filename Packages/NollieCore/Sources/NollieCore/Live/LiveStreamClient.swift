import Foundation
import Network
import Security
import Synchronization

/// A live picture over the network: one WebSocket to `/nollie/live` on the chat's gateway. A
/// linked Mac must show its pinned key over TLS 1.3, other https gateways get the system's usual
/// checks, and plain http (the demo gateway on this computer) none. The connection is marked as
/// interactive video and sends small writes at once, so a keyframe request never waits.
public final class LiveStreamClient: LiveFeed {
    /// Where the stream opens and how it proves who is asking.
    public struct Target: Sendable {
        /// `ws(s)://<gateway>/nollie/live?profile=…&session_id=…`, with no credential in it.
        public var url: URL
        /// The session token (on a linked phone, its device credential), sent as a header.
        public var token: String
        /// The key a linked Mac must show, or nil for any other gateway.
        public var pin: Data?
        /// Headers every request to this gateway carries anyway (Cloudflare Access).
        public var headers: [String: String]

        public init(url: URL, token: String, pin: Data? = nil, headers: [String: String] = [:]) {
            self.url = url; self.token = token; self.pin = pin; self.headers = headers
        }

        /// The stream for one chat on `gateway`.
        public init(gateway: GatewayURL, profile: String, sessionID: String, token: String, pin: Data? = nil,
                    headers: [String: String] = [:]) {
            self.init(url: gateway.websocket(LiveWire.path, query: [URLQueryItem(name: "profile", value: profile),
                                                                     URLQueryItem(name: "session_id", value: sessionID)]),
                      token: token, pin: pin, headers: headers)
        }
    }

    public let events: AsyncStream<LiveFeedEvent>
    private let inbox: Inbox
    private let connection: NWConnection?
    private let queue = DispatchQueue(label: "com.coreykozarski.nollie.live.client", qos: .userInteractive)
    private let state = Mutex(State())

    private struct State {
        var ready = false
        var greeted = false
        var ended: LiveWire.EndReason?
        /// A read is waiting on the connection. It always comes back once the connection fails or is
        /// cancelled, bringing any last message (often the end) before its error.
        var reading = false
    }

    /// Delays the handling of each read by this long, as a device too busy to get to it would. Tests only.
    private let readDelay: TimeInterval

    /// Opens at once. Without a target (a gateway signed in some other way) the feed closes as
    /// unavailable straight away, and the app keeps its snapshots. `readDelay` is for tests.
    public init(target: Target?, helloTimeout: TimeInterval = 10, readDelay: TimeInterval = 0) {
        self.readDelay = readDelay
        let inbox = Inbox()
        self.inbox = inbox
        events = AsyncStream(unfolding: { await inbox.next() }, onCancel: { inbox.readerLeft() })
        guard let target, ["ws", "wss"].contains(target.url.scheme), !target.token.isEmpty else {
            connection = nil
            inbox.finish(.unavailable)
            return
        }
        let connection = NWConnection(to: .url(target.url), using: Self.parameters(for: target))
        self.connection = connection
        // The task reading the events was cancelled: nobody is watching.
        inbox.onReaderLeft { [weak self] in self?.cancel() }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.state.withLock { $0.ready = true }
                receive()
            // Waiting means no route or a refusal; a live picture that late is no use. Once
            // ready, the read that is out ends the feed when it comes back, after any last message
            // (often the end) that came before the error. It always comes back once the connection
            // has failed or is cancelled; a connection left waiting is cancelled so that it does.
            // Closing on a one-second timer instead lost the end whenever the device took longer than
            // that to get to the read, and the person was told the stream dropped, not why it ended.
            case .waiting, .failed, .cancelled:
                guard self.state.withLock({ $0.ready && $0.reading }) else { close(); return }
                if case .waiting = state { self.connection?.cancel() }
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + helloTimeout) { [weak self] in
            guard let self, !state.withLock({ $0.greeted }) else { return }
            close()
        }
    }

    deinit {
        connection?.cancel()
        inbox.finish(.cancelled)
    }

    static func parameters(for target: Target) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        var tls: NWProtocolTLS.Options?
        if target.url.scheme == "wss" {
            let options = NWProtocolTLS.Options()
            let security = options.securityProtocolOptions
            sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
            if let pin = target.pin {
                sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
                sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
                sec_protocol_options_set_verify_block(security, { _, trust, complete in
                    complete(NollieLinkPin.matches(sec_trust_copy_ref(trust).takeRetainedValue(), pin: pin))
                }, DispatchQueue.global(qos: .userInitiated))
            }
            tls = options
        }
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        parameters.includePeerToPeer = false
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        socket.maximumMessageSize = LiveWire.maximumMessage
        var headers = target.headers.filter { $0.key.caseInsensitiveCompare(RequestSigner.sessionTokenHeader) != .orderedSame }
            .map { (name: $0.key, value: $0.value) }
        headers.append((name: RequestSigner.sessionTokenHeader, value: target.token))
        socket.setAdditionalHeaders(headers)
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        return parameters
    }

    // MARK: LiveFeed

    public func send(_ message: LiveWire.ViewerMessage) {
        guard let connection, !inbox.closed else { return }
        var message = message
        // Frames dropped here for a reader that fell behind are late too.
        if case .report(var report) = message {
            let dropped = inbox.takeDropped()
            report.got += dropped
            report.late += dropped
            message = .report(report)
        }
        let text = Data(message.encode().utf8)
        guard text.count <= LiveWire.maximumViewerText else { return }
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: text, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    public func cancel() {
        guard let connection, inbox.finish(.cancelled) else { return }
        // Say goodbye properly, but never wait long for it.
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
    }

    // MARK: Reading

    private func receive() {
        guard let connection else { return }
        state.withLock { $0.reading = true }
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            guard readDelay <= 0 else {
                queue.asyncAfter(deadline: .now() + readDelay) { [weak self] in self?.handle(content, context, error) }
                return
            }
            handle(content, context, error)
        }
    }

    /// One read come back: its message, if any, then the next read, or the end of the feed.
    private func handle(_ content: Data?, _ context: NWConnection.ContentContext?, _ error: NWError?) {
        state.withLock { $0.reading = false }
        // The last message can arrive together with the error that ends the connection.
        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
        switch metadata?.opcode {
        case .text?: if let content { text(content) }
        case .binary?: if let content { video(content) }
        default: break
        }
        guard error == nil, let metadata, metadata.opcode != .close else { close(); return }
        if !inbox.closed { receive() }
    }

    private func text(_ data: Data) {
        // Messages this version doesn't know are skipped, so a newer host can say more.
        guard let message = try? LiveWire.ServerMessage.decode(String(decoding: data, as: UTF8.self)), !inbox.closed else { return }
        state.withLock { state in
            if case .hello = message { state.greeted = true }
            if case .end(let reason) = message { state.ended = reason }
        }
        inbox.post(.message(message))
    }

    private func video(_ data: Data) {
        guard state.withLock({ $0.greeted }) else { return }
        guard let video = try? LiveWire.decodeVideo(data) else {
            // A frame this viewer can't read: skip it and start again from a keyframe.
            send(.keyframe)
            return
        }
        if inbox.post(video, receivedAt: Date()) == .droppedAskingForKeyframe { send(.keyframe) }
    }

    /// The connection ended from the other side, failed, or never got going.
    private func close() {
        let close = state.withLock { state -> LiveFeedClose in
            if let reason = state.ended { return .ended(reason) }
            return state.greeted ? .dropped : .unavailable
        }
        if inbox.finish(close) { connection?.cancel() }
    }
}

extension LiveStreamClient {
    /// What has arrived and the reader hasn't taken yet. The reader takes one event at a time, so
    /// one that falls behind (a busy main thread) leaves frames waiting here, and frames drop
    /// rather than queue: at most a couple wait, then only a keyframe can follow, and a keyframe
    /// replaces any frames still waiting. Messages are small and never dropped.
    final class Inbox: Sendable {
        enum Admission: Equatable {
            case posted
            /// Dropped, and the first since the last keyframe: the host should send one.
            case droppedAskingForKeyframe
            case dropped
        }

        /// Frames that may wait for the reader before newer ones are dropped.
        static let backlog = 2

        private struct Box {
            var waiting: [LiveFeedEvent] = []
            var videos = 0
            var reader: CheckedContinuation<LiveFeedEvent?, Never>?
            var closed = false
            var skipping = false
            var dropped = 0
            var readerLeft: (@Sendable () -> Void)?

            /// The reader, when it is waiting and should get `event` at once; else it waits here.
            mutating func post(_ event: LiveFeedEvent) -> CheckedContinuation<LiveFeedEvent?, Never>? {
                if let reader {
                    self.reader = nil
                    return reader
                }
                waiting.append(event)
                if case .video = event { videos += 1 }
                return nil
            }
        }

        private let box = Mutex(Box())

        /// The `.closed` event has been posted, and nothing more will be.
        var closed: Bool { box.withLock { $0.closed } }

        func onReaderLeft(_ handler: @escaping @Sendable () -> Void) { box.withLock { $0.readerLeft = handler } }

        func readerLeft() { box.withLock { $0.readerLeft }?() }

        func post(_ event: LiveFeedEvent) {
            box.withLock { $0.closed ? nil : $0.post(event) }?.resume(returning: event)
        }

        func post(_ video: LiveWire.Video, receivedAt: Date) -> Admission {
            let event = LiveFeedEvent.video(video, receivedAt: receivedAt)
            let (admission, reader) = box.withLock { box -> (Admission, CheckedContinuation<LiveFeedEvent?, Never>?) in
                guard !box.closed else { return (.dropped, nil) }
                if video.keyframe {
                    box.skipping = false
                    if box.videos > 0 {
                        box.waiting.removeAll { if case .video = $0 { true } else { false } }
                        box.dropped += box.videos
                        box.videos = 0
                    }
                } else if box.skipping || box.videos >= Self.backlog {
                    box.dropped += 1
                    defer { box.skipping = true }
                    return (box.skipping ? .dropped : .droppedAskingForKeyframe, nil)
                }
                return (.posted, box.post(event))
            }
            reader?.resume(returning: event)
            return admission
        }

        /// Frames dropped since the last time this was asked.
        func takeDropped() -> Int {
            box.withLock { box in
                defer { box.dropped = 0 }
                return box.dropped
            }
        }

        /// Posts the one `.closed`. False when the feed had already closed.
        @discardableResult
        func finish(_ close: LiveFeedClose) -> Bool {
            let event = LiveFeedEvent.closed(close)
            let (first, reader) = box.withLock { box -> (Bool, CheckedContinuation<LiveFeedEvent?, Never>?) in
                guard !box.closed else { return (false, nil) }
                box.closed = true
                box.readerLeft = nil
                return (true, box.post(event))
            }
            reader?.resume(returning: event)
            return first
        }

        /// The next event, waiting for one if need be; nil after `.closed`.
        func next() async -> LiveFeedEvent? {
            await withCheckedContinuation { (reader: CheckedContinuation<LiveFeedEvent?, Never>) in
                let ready = box.withLock { box -> LiveFeedEvent?? in
                    if !box.waiting.isEmpty {
                        let event = box.waiting.removeFirst()
                        if case .video = event { box.videos -= 1 }
                        return .some(event)
                    }
                    if box.closed { return .some(nil) }
                    box.reader = reader
                    return nil
                }
                if let ready { reader.resume(returning: ready) }
            }
        }
    }
}
