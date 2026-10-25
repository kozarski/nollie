import Foundation

/// Opens gateway sockets with `URLSessionWebSocketTask`.
public struct WebSocketGatewayTransport: GatewayTransport {
    /// Replay answers can carry a whole session's buffered events (Hermes keeps up to 4 MiB per session).
    public var maximumMessageSize = 32 * 1024 * 1024
    public var configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    public func open(_ endpoint: GatewayEndpoint) async throws -> any GatewayChannel {
        var request = URLRequest(url: endpoint.url)
        for (name, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: name) }
        if !endpoint.subprotocols.isEmpty {
            request.setValue(endpoint.subprotocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        let channel = WebSocketGatewayChannel()
        let session = URLSession(configuration: configuration, delegate: channel, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageSize
        try await channel.start(task, session: session)
        return channel
    }
}

/// One socket. The URLSession delegate callbacks and the receive loop report into `incoming`.
final class WebSocketGatewayChannel: NSObject, GatewayChannel, URLSessionWebSocketDelegate, @unchecked Sendable {
    let incoming: AsyncStream<GatewayChannelEvent>
    private let feed: AsyncStream<GatewayChannelEvent>.Continuation
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var opening: CheckedContinuation<Void, any Error>?
    private var finished = false

    override init() {
        (incoming, feed) = AsyncStream.makeStream(of: GatewayChannelEvent.self)
        super.init()
    }

    func start(_ task: URLSessionWebSocketTask, session: URLSession) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock {
                    self.task = task
                    self.session = session
                    opening = continuation
                }
                task.resume()
            }
        } onCancel: {
            self.failOpening(GatewayTransportError.unreachable("cancelled"))
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    func send(_ text: String) {
        guard let task = lock.withLock({ finished ? nil : self.task }) else { return }
        task.send(.string(text)) { [weak self] error in
            if error != nil { self?.finish(code: nil, reason: "send failed") }
        }
    }

    func close(code: Int) {
        guard let task = lock.withLock({ finished ? nil : self.task }) else { return }
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
        finish(code: code, reason: nil)
    }

    private func receiveNext(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(.string(let text)):
                feed.yield(.text(text))
                receiveNext(task)
            case .success(.data(let data)):
                feed.yield(.text(String(decoding: data, as: UTF8.self)))
                receiveNext(task)
            case .success:
                receiveNext(task)
            case .failure:
                let code = task.closeCode == .invalid ? nil : task.closeCode.rawValue
                finish(code: code, reason: task.closeReason.map { String(decoding: $0, as: UTF8.self) })
            }
        }
    }

    private func failOpening(_ error: any Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { opening = nil }
            return opening
        }
        continuation?.resume(throwing: error)
    }

    private func finish(code: Int?, reason: String?) {
        let session = lock.withLock { () -> URLSession? in
            guard !finished else { return nil }
            finished = true
            return self.session
        }
        guard let session else { return }
        feed.yield(.closed(code: code, reason: reason))
        feed.finish()
        session.invalidateAndCancel()
    }

    // URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { opening = nil }
            return opening
        }
        receiveNext(webSocketTask)
        continuation?.resume()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(code: closeCode.rawValue, reason: reason.map { String(decoding: $0, as: UTF8.self) })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
            failOpening(GatewayTransportError.refused(status: status))
        } else {
            // Only the error's kind, never its text: URL errors can include the address and its ticket.
            failOpening(GatewayTransportError.unreachable(error.map { "\(type(of: $0)) \(($0 as NSError).code)" } ?? "closed"))
        }
        let code = (task as? URLSessionWebSocketTask).map(\.closeCode).flatMap { $0 == .invalid ? nil : $0.rawValue }
        finish(code: code, reason: nil)
    }
}
