#if os(macOS)
import Foundation

/// The rules of Papertrail's network filter, without the system around them: which connections belong to
/// Hermes's process tree, which of those went around Papertrail's door, and whose they were. Shared by the
/// filter (a Network Extension content filter in the Direct edition), Nollie Runtime and the tests.
///
/// The filter sees every new flow on the Mac. A flow from Nollie Runtime's children or their children that
/// goes anywhere but loopback did not come through the door (the door's own connections leave from Nollie
/// Runtime itself, which is not a child). Such a flow is reported, and refused when Refuse is on.
enum NetworkFilterPolicy {
    /// The filter's Mach service. A system extension's service name starts with the team's app group.
    static let machService = "5985LRZFZS.com.coreykozarski.nollie.network-filter"
    static let filterBundleID = "com.coreykozarski.nollie.network-filter"
    static let runtimeBundleID = "com.coreykozarski.nollie.runtime"
    static let teamID = "5985LRZFZS"
    /// The longest chain of parents walked from a flow's process to Nollie Runtime.
    static let maximumDepth = 32

    /// The switch, written by Nollie on the Mac into `RuntimeService/network-filter.json`: off unless it says on.
    struct Switch: Codable, Equatable, Sendable {
        static let fileName = "network-filter.json"
        var version = 1
        /// Report connections that went around the door.
        var on = false
        /// Also refuse them, and have the door refuse programs it can't place with a bot.
        var refuse = false

        static let off = Switch()

        init(on: Bool = false, refuse: Bool = false) {
            self.on = on
            self.refuse = refuse
        }

        /// A key left out means off.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            on = try values.decodeIfPresent(Bool.self, forKey: .on) ?? false
            refuse = try values.decodeIfPresent(Bool.self, forKey: .refuse) ?? false
        }

        static func read(_ data: Data?) -> Switch {
            guard let data, data.count <= 4096, let value = try? JSONDecoder().decode(Switch.self, from: data),
                  value.version == 1 else { return .off }
            return Switch(on: value.on, refuse: value.on && value.refuse)
        }
    }

    /// One process on the way up from a flow: its id, its parent's, and whether it is Nollie Runtime itself
    /// (by its signature, checked by the caller).
    struct Ancestor: Equatable, Sendable {
        var pid: Int32
        var parent: Int32
        var isRuntime: Bool
    }

    enum Verdict: Equatable, Sendable {
        /// Not Hermes's, or Hermes's through the door: nothing to do.
        case allow
        /// Hermes's, around the door: reported, then allowed.
        case report
        /// Hermes's, around the door, with Refuse on: reported as refused, and dropped.
        case refuse
    }

    /// `chain` starts at the flow's own process and goes up through its parents.
    static func verdict(chain: [Ancestor], remoteIsLoopback: Bool, switch: Switch) -> Verdict {
        guard `switch`.on, !remoteIsLoopback, let first = chain.first, !first.isRuntime,
              chain.prefix(maximumDepth).dropFirst().contains(where: \.isRuntime) else { return .allow }
        return `switch`.refuse ? .refuse : .report
    }

    /// Whether an address is this Mac's own loopback.
    static func isLoopback(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || name == "::1" { return true }
        if name.hasPrefix("::ffff:") { return isLoopback(String(name.dropFirst(7))) }
        if let v4 = ExitRelayTarget.dottedQuad(Substring(name)) { return v4[0] == 127 }
        return false
    }

    // MARK: Whose it was

    /// What `KERN_PROCARGS2` holds for a process: its arguments and its environment as it started.
    struct Arguments: Equatable, Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String]
    }

    /// Reads `KERN_PROCARGS2`: an argument count, the executable path, padding, then the arguments and the
    /// environment, each NUL-terminated. Nil for anything malformed.
    static func arguments(_ data: Data) -> Arguments? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let count = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard count >= 0, count < 65_536 else { return nil }
        var index = 4
        func string() -> String? {
            guard index < bytes.count, let end = bytes[index...].firstIndex(of: 0) else { return nil }
            defer { index = end + 1 }
            return String(decoding: bytes[index..<end], as: UTF8.self)
        }
        guard let executable = string() else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            guard let value = string() else { return nil }
            arguments.append(value)
        }
        var environment: [String] = []
        while index < bytes.count, bytes[index] != 0, environment.count < 4096, let value = string() {
            environment.append(value)
        }
        return Arguments(executable: executable, arguments: arguments, environment: environment)
    }

    /// The bot and kind a process was labelled with when it started (Papertrail's door label in its proxy
    /// variables), or nil when it carries none or only the unplaced one.
    static func label(environment: [String]) -> (bot: String, kind: String)? {
        for name in ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy"] {
            guard let entry = environment.first(where: { $0.hasPrefix(name + "=") }) else { continue }
            let value = entry.dropFirst(name.count + 1)
            guard value.hasPrefix("http://"), let at = value.firstIndex(of: "@") else { continue }
            let credentials = value[value.index(value.startIndex, offsetBy: 7)..<at]
            guard let colon = credentials.firstIndex(of: ":") else { continue }
            if let label = PapertrailDoorBook.label(String(credentials[..<colon])) { return label }
        }
        return nil
    }

    /// What the filter tells Nollie Runtime about one connection. Never a path beyond the program's name,
    /// never an argument or a byte.
    struct Event: Codable, Equatable, Sendable {
        var at: Double
        var pid: Int32
        /// The program's file name, for the kind ("curl", "ssh", "node").
        var program: String
        var host: String
        var port: Int
        /// `tcp` or `udp`.
        var transport: String
        /// From the process's door label, or the nearest parent's; empty when none could be found.
        var bot: String
        var refused: Bool
    }
}
#endif
