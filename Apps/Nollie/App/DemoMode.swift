import Foundation
import NollieCore

#if DEBUG
/// Demo build for screen recordings: the debug app under a second bundle id (suffix `.demo`),
/// ad-hoc signed. Its settings are separate, and the real gateways and chats stay out of reach.
/// The scripts in Tools/dev build the copies, one for the Mac and one for an iPhone simulator.
///
/// No Keychain is available here, so credentials stay in memory. Launch arguments choose content:
///   -nollie-demo-gateway (then url, token, name)  saves a gateway and connects at launch
///   -nollie-demo-biometry yes|no                  stands in for Face ID on the remembered
///                                                 sign-in (simulators lack Face ID)
///   -nollie-demo-watch                            opens Watch in the open chat once its
///                                                 helper is using a computer
/// Release builds contain none of this.
@MainActor
enum DemoMode {
    nonisolated static let isOn = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".demo")

    /// The value that follows `flag` in the launch arguments; nil unless this is the demo copy.
    private static func word(after flag: String) -> String? {
        words(after: flag, count: 1)?.first
    }

    /// The `count` words that follow `flag`, when this is the demo copy and they are all there.
    private static func words(after flag: String, count: Int) -> [String]? {
        guard isOn else { return nil }
        let line = ProcessInfo.processInfo.arguments
        guard let at = line.firstIndex(of: flag), at + count < line.count else { return nil }
        return Array(line[(at + 1)...(at + count)])
    }

    /// `-nollie-demo-reach home|tailscale|away`: the demo acts as a phone linked to a Mac that is
    /// reached at home, over Tailscale, or not at all. "Away" asks the mock gateway.
    static let reach: NollieLinkReach? = {
        switch word(after: "-nollie-demo-reach") {
        case "home": .home
        case "tailscale": .tailnet
        case "away": .away
        default: nil
        }
    }()

    /// `-nollie-demo-tailscale ready|stopped|missing`: what the Mac's Away from home page finds.
    static let tailscale: String? = word(after: "-nollie-demo-tailscale")

    /// `-nollie-demo-exit-relay on|idle|off|failed`: the exit relay as the Mac's helper reports it.
    static let exitRelay: String? = word(after: "-nollie-demo-exit-relay")

    /// `-nollie-demo-permissions fresh|mixed|allowed`: the permission rows against made-up answers,
    /// so a picture never shows a system prompt or the machine's real answers.
    static let permissions: String? = word(after: "-nollie-demo-permissions")

    /// `-nollie-demo-alerts`: iCloud alerts count as on, for the away line's picture.
    static let alertsOn = isOn && ProcessInfo.processInfo.arguments.contains("-nollie-demo-alerts")

    /// Called first at launch, ahead of any Keychain read.
    static func prepare() {
        if isOn { Keychain.memoryOnly = true }
    }

    /// Adds the gateway from the launch arguments to the in-memory store and makes it the active one.
    static func addGateway(to store: ConnectionStore) {
        guard let given = words(after: "-nollie-demo-gateway", count: 3),
              let address = try? GatewayURL.normalize(given[0])
        else { return }
        var connection = GatewayConnection(name: given[2], gateway: address, authMode: .sessionToken)
        connection.connectionKind = "local"
        try? store.upsert(connection, secrets: GatewaySecrets(sessionToken: given[1]))
        store.activeConnectionID = connection.id
    }
}
#else
/// Release builds have no demo copy, but shared code still asks whether it is one.
enum DemoMode {
    static let isOn = false
    static let reach: NollieLinkReach? = nil
    static let tailscale: String? = nil
    static let exitRelay: String? = nil
    static let alertsOn = false
    static let permissions: String? = nil
}
#endif
