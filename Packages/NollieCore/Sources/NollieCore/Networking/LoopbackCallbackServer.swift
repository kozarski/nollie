import Foundation
import Network

/// A tiny web server on 127.0.0.1 that waits for the browser to come back with `?code=&state=`.
public final class LoopbackCallbackServer: @unchecked Sendable {
    private static var thanksPage: String {
        let title = String(localized: "All signed in", table: "Core", comment: "A web page the browser shows after signing in")
        let line = String(localized: "You can head back to Nollie now.", table: "Core", comment: "A web page the browser shows after signing in")
        return """
            <html><body style="font-family:-apple-system;text-align:center;padding-top:4em">\
            <h2>\(title)</h2><p>\(line)</p></body></html>
            """
    }
    private static var holdPage: String {
        let line = String(localized: "Waiting for the gateway...", table: "Core", comment: "A web page the browser shows while signing in")
        return "<html><body><p>\(line)</p></body></html>"
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "Nollie.loopback")
    private let firstCallback = LockedFlag()
    public var onCallback: (@Sendable (String, String) -> Void)?

    public init() throws {
        let tcp = NWParameters.tcp
        tcp.allowLocalEndpointReuse = true
        tcp.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: tcp)
    }

    /// Starts listening and gives back the port the system picked.
    public func start() async throws -> UInt16 {
        let states = AsyncStream<NWListener.State> { continuation in
            listener.stateUpdateHandler = { continuation.yield($0) }
            listener.newConnectionHandler = { [weak self] incoming in self?.answer(incoming) }
            listener.start(queue: queue)
        }
        for await state in states {
            if case .failed(let error) = state { throw error }
            if case .ready = state, let port = listener.port { return port.rawValue }
        }
        throw CancellationError()
    }

    public func stop() { listener.cancel() }

    private func answer(_ incoming: NWConnection) {
        incoming.start(queue: queue)
        incoming.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, _, _ in
            guard let self, let bytes, let text = String(data: bytes, encoding: .utf8) else {
                incoming.cancel()
                return
            }
            let page = deliver(requestText: text) ? Self.thanksPage : Self.holdPage
            let lines = [
                "HTTP/1.1 200 OK",
                "Content-Type: text/html; charset=utf-8",
                "Content-Length: \(page.utf8.count)",
                "Connection: close",
                "",
                page,
            ]
            let response = Data(lines.joined(separator: "\r\n").utf8)
            incoming.send(content: response, completion: .contentProcessed { _ in incoming.cancel() })
        }
    }

    /// Passes the code on (once) when the request carries one. True if it did.
    private func deliver(requestText: String) -> Bool {
        guard let (code, state) = Self.parameters(from: requestText) else { return false }
        if firstCallback.claim() { onCallback?(code, state) }
        return true
    }

    /// Reads `code` and `state` from the request line, as in "GET /callback?code=abc HTTP/1.1".
    private static func parameters(from request: String) -> (String, String)? {
        guard let firstLine = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2,
              let query = URLComponents(string: "http://127.0.0.1" + parts[1])?.queryItems else { return nil }
        let found = query.reduce(into: [String: String]()) { table, item in
            if table[item.name] == nil, let value = item.value { table[item.name] = value }
        }
        guard let code = found["code"] else { return nil }
        return (code, found["state"] ?? "")
    }
}
