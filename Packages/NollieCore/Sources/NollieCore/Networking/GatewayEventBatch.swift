import Foundation

/// Several gateway events travelling to the main actor as one.
///
/// When a long turn kept running while the app was away, thousands of frames arrive at once. Passing
/// them over one by one kept the main thread hopping and redrawing between them, and the app seemed
/// frozen. So the socket fills a single batch until the main actor claims it, and the main actor then
/// takes the lot in one trip.
///
/// Replies and server requests close the batch in progress; the next event opens another. This
/// keeps events and replies lined up exactly as they arrived once they reach the main actor.
public final class GatewayEventBatch: @unchecked Sendable {
    private struct Contents {
        var events: [GatewayEvent] = []
        var closed = false
    }

    private let guarded = Guarded(Contents())

    public init() {}

    /// Adds an event. Returns false when the batch is already taken and a new one is needed.
    func add(_ event: GatewayEvent) -> Bool {
        guarded.withLock { contents in
            if !contents.closed { contents.events.append(event) }
            return !contents.closed
        }
    }

    /// Everything gathered so far, in order. Later events belong to another batch.
    public func take() -> [GatewayEvent] {
        guarded.withLock { contents in
            contents.closed = true
            defer { contents.events = [] }
            return contents.events
        }
    }
}

public extension GatewayEvent {
    /// Events whose text continues the text of the one before.
    static let textPieces = Set(["message.delta", "reasoning.delta"])
    /// Events that only mean "load the list again", however many arrive.
    static let listRefreshes = Set(["cron.changed", "sessions.changed", "projects.changed"])

    /// Keeps just the last of each repeated list refresh (per kind and chat), at its position. In a
    /// long turn every flush announced a change, and each one reloaded the chat list, widget and projects.
    static func droppingRepeatedRefreshes(_ events: [GatewayEvent]) -> [GatewayEvent] {
        var seenLater = Set<[String]>()
        var kept: [GatewayEvent] = []
        for event in events.reversed() {
            if listRefreshes.contains(event.type), !seenLater.insert([event.type, event.sessionID]).inserted { continue }
            kept.append(event)
        }
        return kept.reversed()
    }

    /// Joins neighbouring pieces of text for one chat into the first of them. Handling the
    /// joined piece once is the same as handling each in turn.
    static func coalescingText(_ events: [GatewayEvent]) -> [GatewayEvent] {
        var result: [GatewayEvent] = []
        var pieces: [String] = []

        // Writes the joined text of a finished run into the event that heads it.
        func closeRun() {
            if pieces.count > 1, let head = result.indices.last, case .object(var fields) = result[head].payload {
                fields["text"] = .string(pieces.joined())
                result[head].payload = .object(fields)
            }
            pieces.removeAll()
        }

        for event in events {
            let text = textPieces.contains(event.type) ? event.payload["text"]?.stringValue : nil
            let continuesRun = !pieces.isEmpty && result.last.map { $0.type == event.type && $0.sessionID == event.sessionID } == true
            if let text, continuesRun {
                pieces.append(text)
                result[result.count - 1].seq = event.seq ?? result[result.count - 1].seq
                continue
            }
            closeRun()
            result.append(event)
            if let text, case .object = event.payload { pieces = [text] }
        }
        closeRun()
        return result
    }
}
