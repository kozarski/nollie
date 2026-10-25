import Foundation

/// The plugin's live socket. It stays connected while anyone wants it, retries after longer and
/// longer pauses, and passes along every frame it can decode.
@MainActor
final class KanbanEventStream {
    typealias Opener = @MainActor () async throws -> URLRequest

    private static let session = HermesAPI.makeSession()
    private static let firstPause = 2.0
    private static let longestPause = 30.0

    private var loop: Task<Void, Never>?
    private var open: URLSessionWebSocketTask?

    /// Called with true when a socket is up and false when it drops.
    var onConnection: (Bool) -> Void = { _ in }
    var onFrame: (KanbanEventsFrame) -> Void = { _ in }

    var isRunning: Bool { loop != nil }

    func run(opening request: @escaping Opener) {
        stop()
        loop = Task { [weak self] in await self?.keepOpen(request) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        // A cancelled task doesn't wake `receive()`, so the socket itself is closed to end the
        // wait now instead of when the next frame arrives.
        open?.cancel(with: .goingAway, reason: nil)
        open = nil
        onConnection(false)
    }

    private func keepOpen(_ makeRequest: Opener) async {
        var pause = Self.firstPause
        while !Task.isCancelled {
            do {
                let request = try await makeRequest()
                let socket = Self.session.webSocketTask(with: request)
                open = socket
                socket.resume()
                onConnection(true)
                pause = Self.firstPause
                defer {
                    socket.cancel(with: .goingAway, reason: nil)
                    if open === socket { open = nil }
                }
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    if let frame = Self.frame(in: message) { onFrame(frame) }
                }
            } catch {
                // Stay silent if this loop was cancelled; its replacement could be live already.
                if Task.isCancelled { return }
                onConnection(false)
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(pause))
            pause = min(Self.longestPause, pause * 2)
        }
    }

    private static func frame(in message: URLSessionWebSocketTask.Message) -> KanbanEventsFrame? {
        let bytes: Data
        switch message {
        case .data(let data): bytes = data
        case .string(let text): bytes = Data(text.utf8)
        @unknown default: return nil
        }
        return try? JSONCoding.decoder.decode(KanbanEventsFrame.self, from: bytes)
    }
}

/// Looks at the workers on every board now and then, so the app can show which bots are busy
/// even if the Board page was never opened.
@MainActor
final class KanbanActivityWatch {
    private static let period: Duration = .seconds(8)
    private static let boardListEvery: TimeInterval = 60

    private var loop: Task<Void, Never>?
    /// Bumped on every stop, so a look that was under way when the watch ended is thrown away.
    private(set) var epoch = UUID()

    var isWatching: Bool { loop != nil }

    /// `refreshBoards` reloads the board list about once a minute. `look` takes one look and hands
    /// it back, or returns nil while the app is hidden so that nothing is asked of the gateway.
    func begin(refreshBoards: @escaping @MainActor () async -> Void,
               look: @escaping @MainActor () async -> KanbanActivity?,
               show: @escaping @MainActor (KanbanActivity) -> Void) {
        guard loop == nil else { return }
        let mine = epoch
        loop = Task { [weak self] in
            var lastList = Date()
            while !Task.isCancelled {
                if Date().timeIntervalSince(lastList) >= Self.boardListEvery {
                    await refreshBoards()
                    lastList = Date()
                }
                let seen = await look()
                guard !Task.isCancelled, self?.epoch == mine else { return }
                if let seen { show(seen) }
                do { try await Task.sleep(for: Self.period) } catch { return }
            }
        }
    }

    func end() {
        epoch = UUID()
        loop?.cancel()
        loop = nil
    }
}
