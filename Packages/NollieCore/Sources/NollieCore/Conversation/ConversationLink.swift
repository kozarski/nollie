import Foundation

/// What a conversation needs from the live connection. `GatewayClient` is one; tests use a scripted one.
public protocol ConversationLink: Sendable {
    func currentPhase() async -> GatewayPhase
    /// Calls a method with plain JSON params and waits for its result. Failures are `GatewayCallFailure`.
    func request(_ method: String, _ params: GatewayJSON, timeout: Duration?) async throws -> GatewayJSON
    /// Answers a question Hermes asked.
    func answer(question id: String, method: String, result: GatewayJSON) async
    /// Sets a question aside here so another window that shows the chat can still answer it.
    func decline(question id: String) async
    func watch(session: String, profile: String?) async
    func unwatch(session: String) async
}

extension GatewayClient: ConversationLink {
    public func currentPhase() async -> GatewayPhase { phase }

    public func request(_ method: String, _ params: GatewayJSON, timeout: Duration?) async throws -> GatewayJSON {
        try await callRaw(method, params, timeout: timeout)
    }

    public func answer(question id: String, method: String, result: GatewayJSON) async {
        try? answer(GatewayQuestion<GatewayJSON, GatewayJSON>(name: method), id: id, with: result)
    }

    public func decline(question id: String) async { decline(id: id) }

    public func watch(session: String, profile: String?) async { watch(session: session, profile: profile, from: nil) }
    // `unwatch(session:)` is the client's own.
}
