import Foundation

/// Where a connection to the assistant Nollie runs on this Mac stands while it is not open.
public enum ManagedWait: Equatable, Sendable {
    /// Open, or not a connection Nollie's own service runs.
    case none
    /// The service is starting or coming back (after an update, at login). Nollie keeps asking.
    case starting
    /// Still nothing after the whole wait. Nollie keeps asking, more slowly, and offers Try again.
    case unreachable
}

/// How a connection to the assistant Nollie runs on this Mac comes back by itself.
///
/// After an update the service is registered again and Hermes starts on a new port, which takes
/// from 20 seconds to a few minutes. A gateway elsewhere backs off to half a minute, which left the
/// screens waiting long after the assistant was ready. Asking the service where Hermes is costs
/// one local message, so a managed connection asks every few seconds for the whole wait.
public enum ManagedReconnect {
    /// How long a start may take before the screens say the assistant can't be reached. The
    /// service itself gives Hermes three minutes.
    public static let patience: Double = 180

    /// The pause after failed attempt number `attempt`, `waited` seconds into the wait: one, two,
    /// then three seconds while the assistant may still be starting; afterwards ten seconds for two
    /// minutes and half a minute from then on.
    public static func delay(attempt: Int, waited: Double) -> Double {
        if waited < patience { return Double(min(max(attempt, 1), 3)) }
        return waited < patience + 120 ? 10 : 30
    }

    /// Whether to try at once when the service reports `ready` ready: only for the installation
    /// this connection belongs to, and only while it is not open.
    public static func shouldNudge(waitingFor installation: UUID?, isOpen: Bool, ready: UUID?) -> Bool {
        guard let installation, let ready else { return false }
        return installation == ready && !isOpen
    }

    /// What the screens say about a connection that is `waited` seconds into its wait (nil when
    /// it is not waiting).
    public static func wait(isManaged: Bool, isOpen: Bool, waited: Double?) -> ManagedWait {
        guard isManaged, !isOpen else { return .none }
        guard let waited else { return .starting }
        return waited < patience ? .starting : .unreachable
    }
}

/// How the live socket waits between attempts, and what it does when the gateway refuses its
/// credential.
public struct ReconnectPolicy: Sendable {
    /// Seconds to wait after failed attempt number `attempt`, `waited` seconds after the first failure.
    public var delay: @Sendable (_ attempt: Int, _ waited: Double) -> Double
    /// Run instead of giving up when the gateway refuses the credential; the socket then keeps
    /// trying. Nil gives up, which is right for a gateway someone signs in to.
    public var afterRefusal: (@Sendable () async -> Void)?

    public init(delay: @escaping @Sendable (Int, Double) -> Double, afterRefusal: (@Sendable () async -> Void)? = nil) {
        self.delay = delay
        self.afterRefusal = afterRefusal
    }

    /// A gateway elsewhere: a second for the first three tries, then doubling up to half a minute.
    public static let standard = ReconnectPolicy(delay: { attempt, _ in GatewaySocket.retryDelay(attempt: attempt) })

    /// The assistant Nollie runs on this Mac (see `ManagedReconnect`). A refused credential asks
    /// the service for the current one before the next try.
    public static func managed(afterRefusal: @escaping @Sendable () async -> Void) -> ReconnectPolicy {
        ReconnectPolicy(delay: { ManagedReconnect.delay(attempt: $0, waited: $1) }, afterRefusal: afterRefusal)
    }
}
