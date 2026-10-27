import Foundation
import NollieCore

/// Shares each bot's look through the gateway, so the Mac draws a helper added on the phone the way
/// it was picked there, and the other way round (rules in `SharedBotLooks`). A photo stays on its
/// device. A private bot's look is never sent. A gateway without the workflow add-on simply keeps
/// each device's own looks, as before.
@MainActor
enum BotLookSharing {
    /// Bots whose look changed here and the gateway has not confirmed, per gateway. Until it does,
    /// the gateway's older look must not replace them.
    private static func unsentKey(_ runtime: GatewayRuntime) -> String {
        "botLooks.unsent." + runtime.connection.id.uuidString
    }

    private static func unsent(_ runtime: GatewayRuntime) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: unsentKey(runtime)) ?? [])
    }

    private static func setUnsent(_ names: Set<String>, _ runtime: GatewayRuntime) {
        UserDefaults.standard.set(names.sorted(), forKey: unsentKey(runtime))
    }

    private static var syncedAt: [UUID: Date] = [:]
    private static var syncing: Set<UUID> = []

    /// The person picked a look or colour for this bot here: the gateway hears it now, or at the next sync.
    static func share(_ profile: String, runtime: GatewayRuntime?) {
        guard let runtime, !PrivateBots.isPrivate(profile, connection: runtime.connection.id) else { return }
        setUnsent(unsent(runtime).union([profile]), runtime)
        Task { await send(profile, runtime: runtime) }
    }

    /// Takes the gateway's looks and offers this device's where it has none. At most every 20 seconds unless forced.
    static func sync(_ runtime: GatewayRuntime, force: Bool = false) async {
        let gateway = runtime.connection.id
        guard !syncing.contains(gateway) else { return }
        if !force, let at = syncedAt[gateway], Date().timeIntervalSince(at) < 20 { return }
        syncing.insert(gateway)
        defer { syncing.remove(gateway); syncedAt[gateway] = Date() }

        for profile in unsent(runtime) { await send(profile, runtime: runtime) }
        guard let reply: SharedBotLooks.Reply = try? await runtime.api.get(SharedBotLooks.path),
              let shared = reply.bots, runtime === AppModel.shared.runtime else { return }
        let bots = runtime.profiles.map(\.name).filter { !PrivateBots.isPrivate($0, connection: gateway) }
        let (avatars, colours) = (BotAvatarStore.stored(), BotColors.stored())
        let plan = SharedBotLooks.plan(shared: shared, avatars: avatars, colours: colours, bots: bots, unsent: unsent(runtime))
        if plan.avatars != avatars { BotAvatarStore.save(plan.avatars) }
        if plan.colours != colours { BotColors.save(plan.colours) }
        for (profile, look) in plan.offers.sorted(by: { $0.key < $1.key }) { _ = try? await put(look, for: profile, runtime: runtime) }
    }

    /// Sends this device's current look for one bot; once the gateway has it, it is no longer unsent.
    private static func send(_ profile: String, runtime: GatewayRuntime) async {
        let look = SharedBotLook(avatar: BotAvatarStore.stored()[profile], colour: BotColors.stored()[profile]) ?? SharedBotLook()
        do {
            try await put(look, for: profile, runtime: runtime)
            setUnsent(unsent(runtime).subtracting([profile]), runtime)
        } catch HermesAPIError.http(let status, _) where [403, 404, 422].contains(status) {
            // No add-on, a private bot or a look it can't keep: trying again would not change the answer.
            setUnsent(unsent(runtime).subtracting([profile]), runtime)
        } catch {
            // Kept for the next sync.
        }
    }

    private static func put(_ look: SharedBotLook, for profile: String, runtime: GatewayRuntime) async throws {
        let name = profile.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? profile
        let body: JSONValue = .object(["look": look.look.map(JSONValue.string) ?? .null,
                                       "colour": look.colour.map(JSONValue.string) ?? .null])
        let _: JSONValue = try await runtime.api.send("PUT", SharedBotLooks.path + "/" + name, json: body)
    }
}
