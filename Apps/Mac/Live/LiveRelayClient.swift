#if NOLLIE_DIRECT
import Foundation
import NollieCore
import ServiceManagement
import Synchronization

/// The app's end of the live picture relay. It registers with Nollie Runtime as the one that hosts
/// live pictures, registers again when the helper restarts, and turns the helper's opens, phone
/// messages and closes into this Mac's hosts. Encoded frames go back one way, never waiting.
@MainActor
final class LiveRelayClient {
    static let shared = LiveRelayClient()

    private var connection: LiveRelayConnection?
    private var loop: Task<Void, Never>?
    private var streams: [String: (host: LiveHost, id: LiveHost.ViewerID)] = [:]
    private var closed = NollieLiveRelayClosed()

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.connection == nil, ManagedRuntimeServiceControl.system.status() == .enabled { self.connect() }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func connect() {
        let xpc = NSXPCConnection(machServiceName: NollieLiveRelayConfiguration.machService)
        let connection = LiveRelayConnection(xpc)
        xpc.remoteObjectInterface = NSXPCInterface(with: NollieLiveRelayIPC.self)
        xpc.exportedInterface = NSXPCInterface(with: NollieLiveHostIPC.self)
        xpc.exportedObject = LiveRelayHostExport(connection: connection)
        xpc.setCodeSigningRequirement(NollieRuntimeIPCConfiguration.helperRequirement)
        // The helper restarted: its streams are gone, and it needs to hear from the app again.
        xpc.interruptionHandler = { Task { @MainActor in LiveRelayClient.shared.lost(connection, reconnect: true) } }
        xpc.invalidationHandler = { Task { @MainActor in LiveRelayClient.shared.lost(connection, reconnect: false) } }
        xpc.resume()
        self.connection = connection
        connection.register()
    }

    private func lost(_ lost: LiveRelayConnection, reconnect: Bool) {
        guard connection === lost else { return }
        let open = streams
        streams = [:]
        for stream in open.values { stream.host.detach(stream.id) }
        if reconnect { lost.register() } else { connection = nil }
    }

    // MARK: From the helper

    fileprivate func open(_ request: NollieLiveRelayOpen, on connection: LiveRelayConnection) async -> NollieLiveRelayAnswer {
        // A close can overtake its open: the helper stopped waiting, so nobody would watch.
        guard isWanted(request.stream, on: connection) else { return .ended("unavailable") }
        let viewer = LiveRelayViewer(stream: request.stream, connection: connection) { stream in
            Task { @MainActor in LiveRelayClient.shared.streams[stream] = nil }
        }
        switch await LiveHostCenter.shared.open(profile: request.profile, sessionID: request.sessionID, viewer: viewer, judged: true) {
        case .attached(let host, let id):
            // Closed, or the helper went, while the chat was looked up.
            guard isWanted(request.stream, on: connection) else {
                host.detach(id)
                return .ended("unavailable")
            }
            streams[request.stream] = (host, id)
            return .opened
        case .ended(let reason):
            return .ended(reason.rawValue)
        }
    }

    private func isWanted(_ stream: String, on connection: LiveRelayConnection) -> Bool {
        self.connection === connection && streams[stream] == nil && !closed.contains(stream)
    }

    fileprivate func control(_ input: LiveHost.Input, stream: String, on connection: LiveRelayConnection) {
        guard self.connection === connection, let open = streams[stream] else { return }
        open.host.receive(input, from: open.id)
    }

    fileprivate func close(_ stream: String, on connection: LiveRelayConnection) {
        guard self.connection === connection else { return }
        closed.insert(stream)
        guard let open = streams.removeValue(forKey: stream) else { return }
        open.host.detach(open.id)
    }
}

/// One connection to the helper. XPC connections are safe from any thread.
private final class LiveRelayConnection: @unchecked Sendable {
    let xpc: NSXPCConnection

    init(_ xpc: NSXPCConnection) { self.xpc = xpc }

    var relay: NollieLiveRelayIPC? { xpc.remoteObjectProxyWithErrorHandler { _ in } as? NollieLiveRelayIPC }

    func register() { relay?.register { _ in } }
}

/// The helper's calls. Each is checked here before anything reaches a host.
private final class LiveRelayHostExport: NSObject, NollieLiveHostIPC, @unchecked Sendable {
    private let connection: LiveRelayConnection

    init(connection: LiveRelayConnection) { self.connection = connection }

    func open(request: Data, withReply: @escaping @Sendable (Data) -> Void) {
        guard let request = NollieLiveRelayOpen.decode(request) else {
            return withReply(NollieLiveRelayAnswer.ended("refused").encoded())
        }
        let connection = connection
        Task { @MainActor in withReply(await LiveRelayClient.shared.open(request, on: connection).encoded()) }
    }

    func control(stream: String, message: Data) {
        guard NollieLiveRelay.isStreamID(stream), let input = LiveHost.input(message) else { return }
        let connection = connection
        Task { @MainActor in LiveRelayClient.shared.control(input, stream: stream, on: connection) }
    }

    func close(stream: String) {
        guard NollieLiveRelay.isStreamID(stream) else { return }
        let connection = connection
        Task { @MainActor in LiveRelayClient.shared.close(stream, on: connection) }
    }
}

/// A phone, as a host sees it: every message goes to the helper one way, for the door to relay.
private final class LiveRelayViewer: LiveHostViewer {
    private let stream: String
    private let connection: LiveRelayConnection
    private let ended: @Sendable (String) -> Void
    private let closed = Mutex(false)

    init(stream: String, connection: LiveRelayConnection, ended: @escaping @Sendable (String) -> Void) {
        self.stream = stream
        self.connection = connection
        self.ended = ended
    }

    func send(_ message: LiveWire.ServerMessage) {
        guard !closed.withLock({ $0 }) else { return }
        connection.relay?.push(stream: stream, data: Data(message.encode().utf8), isText: true, isKeyframe: false)
    }

    func send(_ video: LiveWire.Video, encoded: Data) {
        guard !closed.withLock({ $0 }), encoded.count <= NollieLiveRelayConfiguration.videoLimit else { return }
        connection.relay?.push(stream: stream, data: encoded, isText: false, isKeyframe: video.keyframe)
    }

    func end(_ reason: LiveWire.EndReason) {
        guard !closed.withLock({ was in defer { was = true }; return was }) else { return }
        connection.relay?.end(stream: stream, reason: reason.rawValue)
        ended(stream)
    }
}
#endif
