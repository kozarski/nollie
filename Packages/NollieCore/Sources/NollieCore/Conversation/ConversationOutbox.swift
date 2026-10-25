import Foundation

/// What the person typed, in order, and how far each message got. A message is sent at most once by the engine:
/// a send whose answer was lost is `uncertain` and stays so until a snapshot shows it landed or the person decides.
public struct ConversationOutbox: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var text: String
        public var state: State

        public init(id: String, text: String, state: State = .waiting) {
            self.id = id
            self.text = text
            self.state = state
        }
    }

    public enum State: Codable, Hashable, Sendable {
        /// Not sent yet: typed while offline, before the chat was attached, or while a turn ran.
        case waiting
        /// The one send in flight.
        case sending
        /// Hermes has it.
        case sent
        /// The answer was lost; Hermes may or may not have it.
        case uncertain
        /// Hermes refused it.
        case failed(String)
    }

    public private(set) var entries: [Entry] = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// The outbox as saved, read back after a launch: a message that was going out may have left before the app
    /// stopped, so it is uncertain now. Sent ones are history.
    public static func restored(_ saved: ConversationOutbox) -> ConversationOutbox {
        ConversationOutbox(entries: saved.entries.compactMap { entry in
            var entry = entry
            switch entry.state {
            case .sent: return nil
            case .sending: entry.state = .uncertain
            default: break
            }
            return entry
        })
    }

    public subscript(id: String) -> Entry? { entries.first { $0.id == id } }

    public var waiting: [Entry] { entries.filter { $0.state == .waiting } }
    public var inFlight: Entry? { entries.first { $0.state == .sending } }
    public var uncertain: [Entry] { entries.filter { $0.state == .uncertain } }

    /// The next message to send, if the line and the chat allow one now.
    public func next(canSend: Bool) -> Entry? {
        guard canSend, inFlight == nil else { return nil }
        return entries.first { $0.state == .waiting }
    }

    mutating func add(_ entry: Entry) { entries.append(entry) }

    mutating func set(_ id: String, _ state: State) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].state = state
    }

    mutating func remove(_ id: String) { entries.removeAll { $0.id == id } }

    /// Sent messages are kept until their turn ends, then forgotten.
    mutating func forgetSent() { entries.removeAll { $0.state == .sent } }
}

/// How a send ended, as far as this device can tell.
public enum ConversationSendOutcome: Hashable, Sendable {
    case accepted(userRowId: Int?)
    /// Hermes answered with an error. `retryable` when it only means "not yet" (the agent is still starting).
    case refused(String, retryable: Bool)
    /// It never left the device.
    case notSent
    /// The answer was lost after it left.
    case uncertain
}
