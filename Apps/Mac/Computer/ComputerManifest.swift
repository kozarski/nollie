import Foundation

/// The driver's capability manifests (Cua Driver's version 3 format), built only from apps the
/// person approved. The driver enforces them itself, so they hold even for a call that never
/// went through Nollie's own checks.
///
/// - `door`: the helper's process-wide manifest. Its socket admits any process running as this
///   user, so that door allows nothing but a permission check.
/// - `use`: one trusted session, open only to Nollie (the helper's parent), for the apps the bot
///   may act in: look, click, type, press keys, scroll. Never launching, quitting, menus,
///   scripts, the clipboard, the whole screen or files.
/// - `view`: a second trusted session for view-only apps (browsers): look only.
///
/// Each session's idle limit is the task's whole lifetime; Nollie ends the task after 5 minutes
/// without an action in either session, and stops the helper.
enum ComputerManifest {
    static let lookTools = ["list_windows", "get_window_state"]
    static let actTools = ["click", "type_text", "press_key", "hotkey", "scroll"]

    static func door(lifetime: TimeInterval = ComputerTask.lifetime) -> String {
        let limit = "\(Int(lifetime) + 60)s"
        return """
        version: 3
        expires_after: \(limit)
        idle_timeout: \(limit)
        allow:
          tools: [check_permissions]
        resources:
          desktop:
            display: false

        """
    }

    /// The `use` session's manifest, or nil when every approved app is view-only.
    static func use(_ apps: [ComputerTask.App]) -> String? {
        session(apps.filter { !$0.viewOnly }, tools: lookTools + actTools)
    }

    /// The `view` session's manifest, or nil when no approved app is view-only.
    static func view(_ apps: [ComputerTask.App]) -> String? {
        session(apps.filter(\.viewOnly), tools: lookTools)
    }

    private static func session(_ apps: [ComputerTask.App], tools: [String]) -> String? {
        let ids = Array(Set(apps.map(\.bundleID))).sorted()
        guard !ids.isEmpty else { return nil }
        let entries = ids.map { id in
            """
                - bundle_id: \(yamlString(id))
                  windows: all
                  terminate: deny
            """
        }.joined(separator: "\n")
        return """
        version: 3
        expires_after: \(Int(ComputerTask.lifetime))s
        idle_timeout: \(Int(ComputerTask.lifetime))s
        allow:
          tools: [\(tools.joined(separator: ", "))]
        resources:
          apps:
        \(entries)
          desktop:
            display: false

        """
    }

    /// A double-quoted YAML scalar. Bundle ids are plain, but nothing from outside is trusted.
    static func yamlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: out += String(format: "\\x%02X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
