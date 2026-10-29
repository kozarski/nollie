#if os(macOS)
import Foundation
import NollieCore

/// The nollie-mac add-on in Nollie's own setup: listed, with its MCP server on Nollie's own Python,
/// only in bots with This Mac on. Nollie Runtime copies it into every bot that is not private and
/// sets this at each start, from the bot's desktop lease (`managed_addons.py`); turning This Mac on
/// or off on this Mac applies it at once, for chats started from then on. Private bots never get it.
@MainActor
enum ComputerManagedAddOn {
    nonisolated static let name = "nollie-mac"

    /// Nollie's own Python for a setup: the interpreter its installer put there.
    nonisolated static func python(installation: UUID, setups: URL = NolliePaths.current.setups) -> String {
        setups.appendingPathComponent(installation.uuidString)
            .appendingPathComponent("python/" + NativeSetupPlan.pythonKey + "/bin/python3.14").path
    }

    /// The bot's plugin list with nollie-mac in it or not, everything else kept in order.
    nonisolated static func enabled(_ list: [String], on: Bool) -> [String] {
        let kept = list.filter { $0.split(separator: "/").last.map(String.init) != name }
        return on ? kept + [name] : kept
    }

    /// The MCP server entry: exactly the add-on's server.py in the bot's own plugin folder, on Nollie's Python.
    nonisolated static func server(python: String, home: String) -> [String: JSONValue] {
        ["name": .string(name), "command": .string(python),
         "args": .array([.string("-I"), .string(home + "/plugins/" + name + "/server.py")])]
    }

    /// Applies This Mac to the bot's config through Hermes. Only for Nollie's own setup and a bot
    /// that is not private; a bot whose copy hasn't arrived yet gets it at the next start.
    static func apply(_ on: Bool, profile: String, home: String, rt: GatewayRuntime) async {
        guard let installation = rt.connection.managedInstallationID,
              !SystemControl.isPrivate(profile, connection: rt.connection.id),
              FileManager.default.fileExists(atPath: home + "/plugins/" + name + "/server.py") else { return }
        guard let cfg: JSONValue = try? await rt.api.get("/api/config", profile: profile) else { return }
        let root = cfg["config"] ?? cfg
        let list = (root["plugins"]?["enabled"]?.arrayValue ?? []).compactMap(\.stringValue)
        // Replaced, never merged into: a server written by anyone else is not kept.
        _ = try? await rt.api.raw("DELETE", "/api/mcp/servers/" + name, profile: profile, body: nil, authenticated: true, answers: [404])
        if on {
            let body = try? JSONEncoder().encode(JSONValue.object(server(python: python(installation: installation), home: home)))
            if let body {
                _ = try? await rt.api.raw("POST", "/api/mcp/servers", profile: profile, body: (body, "application/json"), authenticated: true)
            }
        }
        let wanted = enabled(list, on: on)
        if wanted != list {
            let _: JSONValue? = try? await rt.api.send("PUT", "/api/config", profile: profile,
                                                       json: ["config": .object(["plugins": .object(["enabled": .array(wanted.map { .string($0) })])])])
        }
    }
}
#endif
