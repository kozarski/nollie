import Foundation

/// The calls a conversation has in flight, what each was for, and what its result means. It allows one attach and
/// one send at a time, and turns a lost answer into "unknown" for anything that changes Hermes, so nothing that
/// may have happened is done again.
public struct ConversationRequestBook: Hashable, Sendable {
    public enum Purpose: Hashable, Sendable {
        /// `session.resume`. `full` asks for the whole snapshot (after a reload).
        case attach(full: Bool)
        case submit(outboxId: String)
        case approvalAnswer(cardId: String)
        case interrupt

        /// Whether Hermes may have changed something because of it.
        public var mutates: Bool {
            switch self {
            case .attach: false
            case .submit, .approvalAnswer, .interrupt: true
            }
        }
    }

    public struct Ticket: Hashable, Sendable {
        public let number: Int
        public let purpose: Purpose
    }

    /// What a finished call means.
    public enum Outcome: Hashable, Sendable {
        case answered(GatewayJSON)
        case refused(GatewayRPCError)
        /// It never reached the socket; safe to try again.
        case notSent
        /// It may have reached Hermes. For a mutation: never repeat it on its own.
        case unknown
    }

    private var open: [Int: Purpose] = [:]
    private var nextNumber = 1

    public init() {}

    public var count: Int { open.count }
    public var attachInFlight: Bool { open.values.contains { if case .attach = $0 { true } else { false } } }
    public var submitInFlight: Bool { open.values.contains { if case .submit = $0 { true } else { false } } }

    /// Records a call about to be made. Nil when the same kind of call is already in flight and must not be doubled.
    public mutating func begin(_ purpose: Purpose) -> Ticket? {
        switch purpose {
        case .attach where attachInFlight: return nil
        case .submit where submitInFlight: return nil
        case .approvalAnswer(let card) where open.values.contains(.approvalAnswer(cardId: card)): return nil
        default: break
        }
        let ticket = Ticket(number: nextNumber, purpose: purpose)
        nextNumber += 1
        open[ticket.number] = purpose
        return ticket
    }

    /// The call finished. Returns its outcome, or nil if the ticket was already closed.
    public mutating func finish(_ ticket: Ticket, _ result: Result<GatewayJSON, any Error>) -> Outcome? {
        guard open.removeValue(forKey: ticket.number) != nil else { return nil }
        return Self.classify(result)
    }

    /// Sorts a client result into what it means for the caller.
    public static func classify(_ result: Result<GatewayJSON, any Error>) -> Outcome {
        switch result {
        case .success(let answer):
            return .answered(answer)
        case .failure(let error):
            switch error as? GatewayCallFailure {
            case .refused(let rpc): return .refused(rpc)
            case .closed: return .notSent
            case .connectionLost, .timedOut, .cancelled: return .unknown
            case nil:
                // Not a call failure: the answer came and could not be read. Hermes acted.
                if error is CancellationError { return .unknown }
                return .answered(.null)
            }
        }
    }
}
