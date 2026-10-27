import Foundation
import Observation
import NollieCore

/// One bot's Ask first switch. A lost answer leaves the switch unknown until the next read.
@MainActor @Observable
final class AskFirstModel {
    private(set) var enabled: Bool?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var needsTurnOffConfirmation = false
    private var scope: Scope?
    private var operation = UUID()
    private let apiOverride: HermesAPI?
    private let isPrivate: (String) -> Bool

    private struct Scope: Equatable {
        var bot: String
        var connection: UUID
        var gateway: GatewayURL

        @MainActor init(bot: String, runtime: GatewayRuntime) {
            self.bot = bot
            connection = runtime.connection.id
            gateway = runtime.connection.gateway
        }
    }

    private struct Reply: Decodable, Sendable {
        var profile: String
        var enabled: Bool
    }

    private enum Failure: Error { case unconfirmed }
    private static let path = "/api/plugins/nollie-computer/ask-first"

    init(api: HermesAPI? = nil, isPrivate: @escaping (String) -> Bool = { PrivateBots.isPrivate($0) }) {
        apiOverride = api
        self.isPrivate = isPrivate
    }

    func matches(bot: String, runtime: GatewayRuntime) -> Bool {
        scope == Scope(bot: bot, runtime: runtime) && !Self.isPrivateBot(bot, isPrivate: isPrivate)
    }

    func reset() {
        operation = UUID()
        scope = nil
        enabled = nil
        busy = false
        error = nil
        needsTurnOffConfirmation = false
    }

    func load(bot: String, runtime: GatewayRuntime) async {
        guard !Self.isPrivateBot(bot, isPrivate: isPrivate), !Task.isCancelled else { reset(); return }
        let scope = Scope(bot: bot, runtime: runtime)
        if self.scope != scope { reset(); self.scope = scope }
        guard !busy else { return }
        let operation = begin()
        defer { if self.operation == operation { busy = false } }
        let api = apiOverride ?? runtime.api
        do {
            try await check(scope, operation: operation, runtime: runtime, api: api)
            let reply: Reply = try await api.get(Self.path, profile: bot)
            try await check(scope, operation: operation, runtime: runtime, api: api)
            guard reply.profile == bot else { throw Failure.unconfirmed }
            enabled = reply.enabled
            error = nil
        } catch {
            guard self.operation == operation else { return }
            enabled = nil
            needsTurnOffConfirmation = false
            if matches(bot: bot, runtime: runtime), !Task.isCancelled {
                self.error = String(localized: "Couldn't check Ask first. Try again.",
                                    comment: "Safety: Ask first state unknown; keep exact meaning")
            }
        }
    }

    func requestChange(_ on: Bool, bot: String, runtime: GatewayRuntime) async {
        guard !Task.isCancelled, matches(bot: bot, runtime: runtime), !busy, let enabled, enabled != on else { return }
        if on {
            guard let scope else { return }
            let operation = begin()
            await save(true, bot: bot, runtime: runtime, scope: scope, operation: operation)
        } else {
            needsTurnOffConfirmation = true
        }
    }

    func cancelTurnOff() { needsTurnOffConfirmation = false }

    @discardableResult
    func confirmTurnOff(bot: String, runtime: GatewayRuntime) -> Task<Void, Never>? {
        guard needsTurnOffConfirmation else { return nil }
        needsTurnOffConfirmation = false
        guard matches(bot: bot, runtime: runtime), !busy, enabled == true else { return nil }
        guard let scope else { return nil }
        let operation = begin()
        return Task { await save(false, bot: bot, runtime: runtime, scope: scope, operation: operation) }
    }

    private func save(_ on: Bool, bot: String, runtime: GatewayRuntime, scope: Scope, operation: UUID) async {
        defer { if self.operation == operation { busy = false } }
        let api = apiOverride ?? runtime.api
        do {
            try await check(scope, operation: operation, runtime: runtime, api: api)
            let reply: Reply = try await api.send("PUT", Self.path, profile: bot, json: ["enabled": .bool(on)])
            try await check(scope, operation: operation, runtime: runtime, api: api)
            guard reply.profile == bot, reply.enabled == on else { throw Failure.unconfirmed }
            enabled = reply.enabled
            error = nil
        } catch {
            guard self.operation == operation else { return }
            enabled = nil
            if matches(bot: bot, runtime: runtime), !Task.isCancelled {
                self.error = String(localized: "Couldn't confirm that change. Check Ask first again.",
                                    comment: "Safety: an Ask first change was not confirmed; keep exact meaning")
            }
        }
    }

    private func begin() -> UUID {
        operation = UUID()
        busy = true
        error = nil
        needsTurnOffConfirmation = false
        return operation
    }

    static func isPrivateBot(_ bot: String, isPrivate: (String) -> Bool = { PrivateBots.isPrivate($0) }) -> Bool {
        let name = bot.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let names = [name] + name.components(separatedBy: letters.union(CharacterSet(charactersIn: "_-")).inverted)
            + name.components(separatedBy: letters.inverted)
        return names.contains { !$0.isEmpty && ($0 == "private" || $0 == "moss" || isPrivate($0)) }
    }

    private func check(_ scope: Scope, operation: UUID, runtime: GatewayRuntime, api: HermesAPI) async throws {
        try Task.checkCancellation()
        let gateway = await api.gateway
        try Task.checkCancellation()
        guard self.operation == operation, self.scope == scope,
              matches(bot: scope.bot, runtime: runtime), gateway == scope.gateway else { throw Failure.unconfirmed }
    }
}
