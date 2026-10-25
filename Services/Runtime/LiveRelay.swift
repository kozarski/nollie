#if os(macOS)
import Foundation

/// The helper's end of the live picture relay. Nollie.app connects on its own Mach service and
/// registers; from then on a phone's `/nollie/live` asks that app for a feed, and the app's
/// encoded frames go straight to the door. The latest app to register is asked; when it goes,
/// the one before it, still connected, is asked again. With no app registered, the door answers
/// "unavailable" and the phone keeps its snapshots.
final class LiveRelay: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    /// The door's provider, with the relay's listener started once. Only the Direct edition calls it.
    static func start() -> LinkDoor.LiveProvider {
        shared.listen()
        return { request, sink in await shared.open(request, sink: sink) }
    }

    static let shared = LiveRelay()

    /// How long an app may take to answer an open.
    private let openTimeout: TimeInterval
    private let queue = DispatchQueue(label: "com.coreykozarski.nollie.runtime.live")
    // Everything below belongs to `queue`.
    private var listener: NSXPCListener?
    /// Registered apps still connected, newest last. The newest is the one asked.
    private var apps: [LiveRelayApp] = []
    /// Each open stream's phone, and the app that feeds it.
    private var streams: [String: (sink: any LiveRelaySink, app: LiveRelayApp)] = [:]

    private var app: LiveRelayApp? { apps.last }

    init(openTimeout: TimeInterval = 5) { self.openTimeout = openTimeout }

    private func listen() {
        queue.sync {
            guard listener == nil else { return }
            let listener = NSXPCListener(machServiceName: NollieLiveRelayConfiguration.machService)
            listener.delegate = self
            listener.resume()
            self.listener = listener
        }
    }

    /// The same checks as the runtime's own listener: this user, and only the signed app.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.setCodeSigningRequirement(NollieRuntimeIPCConfiguration.hostRequirement)
        let app = LiveRelayApp(connection)
        connection.exportedInterface = NSXPCInterface(with: NollieLiveRelayIPC.self)
        connection.exportedObject = LiveRelayExport(relay: self, app: app)
        connection.remoteObjectInterface = NSXPCInterface(with: NollieLiveHostIPC.self)
        connection.invalidationHandler = { [weak self] in self?.lost(app) }
        connection.resume()
        return true
    }

    // MARK: From the app

    func register(_ connection: LiveRelayApp) {
        queue.async { [self] in
            guard app !== connection else { return }
            // A newer app takes over: every stream ends, on the phone and on the app feeding it.
            endAll()
            apps.removeAll { $0 === connection }
            apps.append(connection)
        }
    }

    fileprivate func push(_ connection: LiveRelayApp, stream: String, data: Data, isText: Bool, isKeyframe: Bool) {
        guard NollieLiveRelay.isStreamID(stream), NollieLiveRelay.acceptsPush(data, isText: isText, isKeyframe: isKeyframe) else { return }
        queue.async { [self] in
            guard let open = streams[stream], open.app === connection else { return }
            open.sink.send(data, isText: isText, isKeyframe: isKeyframe)
        }
    }

    fileprivate func end(_ connection: LiveRelayApp, stream: String, reason: String) {
        guard NollieLiveRelay.isStreamID(stream) else { return }
        let reason = NollieLiveRelay.isEndReason(reason) ? reason : "unavailable"
        queue.async { [self] in
            guard streams[stream]?.app === connection else { return }
            streams.removeValue(forKey: stream)?.sink.end(reason: reason)
        }
    }

    /// An app's connection went away. If it was the one asked, its streams end and the app before
    /// it, if still here, is asked from now on.
    func lost(_ connection: LiveRelayApp) {
        queue.async { [self] in
            guard apps.contains(where: { $0 === connection }) else { return }
            let current = app === connection
            apps.removeAll { $0 === connection }
            if current { endAll() }
        }
    }

    private func endAll() {
        let open = streams
        streams = [:]
        for (stream, entry) in open {
            entry.app.proxy()?.close(stream: stream)
            entry.sink.end(reason: "unavailable")
        }
    }

    // MARK: For the door

    /// Asks the registered app for a feed. Nil, after telling the phone why when the app said.
    func open(_ request: LinkDoorLiveRequest, sink: any LiveRelaySink) async -> LinkDoorLiveFeed? {
        let stream = UUID().uuidString
        let asked = NollieLiveRelayOpen(stream: stream, profile: request.profile, sessionID: request.sessionID).encoded()
        let reply: ReplyOnce.Reply = await withCheckedContinuation { continuation in
            let once = ReplyOnce(continuation)
            queue.async { [self] in
                guard let app else { return once.resume(nil) }
                once.asked(app)
                streams[stream] = (sink, app)
                guard let proxy = app.proxy({ _ in once.resume(nil) }) else { return once.resume(nil) }
                proxy.open(request: asked) { reply in once.resume(NollieLiveRelayAnswer.decode(reply)) }
                queue.asyncAfter(deadline: .now() + openTimeout) { once.resume(nil) }
            }
        }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                // The app may have gone, or ended the stream itself, while it was asked.
                if let answer = reply.answer, answer.open, let asked = reply.app, app === asked, streams[stream]?.sink === sink {
                    return continuation.resume(returning: feed(stream, app: asked))
                }
                if streams.removeValue(forKey: stream) != nil, let reason = reply.answer?.reason { sink.end(reason: reason) }
                // The app may still open it after all: an answer that came too late, or one sent as
                // everything else changed. A close tells it to let go; it ignores streams it doesn't know.
                reply.app?.proxy()?.close(stream: stream)
                continuation.resume(returning: nil)
            }
        }
    }

    /// What the door hands back to the app: the phone's messages and the door's stats, and the close.
    private func feed(_ stream: String, app connection: LiveRelayApp) -> LinkDoorLiveFeed {
        LinkDoorLiveFeed(control: { [self] message in
            guard NollieLiveRelay.acceptsControl(message) else { return }
            queue.async { [self] in
                guard streams[stream]?.app === connection else { return }
                connection.proxy()?.control(stream: stream, message: message)
            }
        }, close: { [self] in
            queue.async { [self] in
                streams.removeValue(forKey: stream)
                // Always the app that opened it, current or not: it lets go of streams it knows
                // and ignores the rest.
                connection.proxy()?.close(stream: stream)
            }
        })
    }
}

/// Where a stream's messages go: the door's sink for the phone.
protocol LiveRelaySink: AnyObject, Sendable {
    func send(_ data: Data, isText: Bool, isKeyframe: Bool)
    func end(reason: String)
}

extension LinkDoorLiveSink: LiveRelaySink {}

/// One app connection. XPC connections are safe from any thread.
final class LiveRelayApp: @unchecked Sendable {
    private let host: (@escaping @Sendable (any Error) -> Void) -> NollieLiveHostIPC?

    init(_ connection: NSXPCConnection) {
        host = { connection.remoteObjectProxyWithErrorHandler($0) as? NollieLiveHostIPC }
    }

    /// An app in the same process, for tests.
    init(host: NollieLiveHostIPC) { self.host = { _ in host } }

    func proxy(_ failed: @escaping @Sendable (any Error) -> Void = { _ in }) -> NollieLiveHostIPC? { host(failed) }
}

/// The app's calls, tied to the connection they came on.
private final class LiveRelayExport: NSObject, NollieLiveRelayIPC, @unchecked Sendable {
    private weak var relay: LiveRelay?
    private let app: LiveRelayApp

    init(relay: LiveRelay, app: LiveRelayApp) {
        self.relay = relay
        self.app = app
    }

    func register(withReply: @escaping @Sendable (Bool) -> Void) {
        guard let relay else { return withReply(false) }
        relay.register(app)
        withReply(true)
    }

    func push(stream: String, data: Data, isText: Bool, isKeyframe: Bool) {
        relay?.push(app, stream: stream, data: data, isText: isText, isKeyframe: isKeyframe)
    }

    func end(stream: String, reason: String) {
        relay?.end(app, stream: stream, reason: reason)
    }
}

/// The app's reply, its error or the timeout: whichever comes first, with the app that was asked.
private final class ReplyOnce: @unchecked Sendable {
    struct Reply: Sendable {
        var answer: NollieLiveRelayAnswer?
        var app: LiveRelayApp?
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Reply, Never>?
    private var app: LiveRelayApp?

    init(_ continuation: CheckedContinuation<Reply, Never>) { self.continuation = continuation }

    func asked(_ app: LiveRelayApp) { lock.withLock { self.app = app } }

    func resume(_ answer: NollieLiveRelayAnswer?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let app = app
        lock.unlock()
        pending?.resume(returning: Reply(answer: answer, app: app))
    }
}
#endif
