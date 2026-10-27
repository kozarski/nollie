#if os(macOS)
import Foundation

enum NollieRuntimeIPCConfiguration {
    static let machService = "com.coreykozarski.nollie.runtime"
    static let plistName = "com.coreykozarski.nollie.runtime.plist"
    static let hostRequirement = #"anchor apple generic and identifier "com.coreykozarski.nollie" and certificate leaf[subject.OU] = "5985LRZFZS""#
    static let helperRequirement = #"anchor apple generic and identifier "com.coreykozarski.nollie.runtime" and certificate leaf[subject.OU] = "5985LRZFZS""#
}

/// Only the signed app can use this local interface. Credentials are never part
/// of the status document and are returned only by an explicit successful start.
@objc(NollieRuntimeIPC) protocol NollieRuntimeIPC {
    func start(installationID: String, withReply: @escaping @Sendable (Data, String?) -> Void)
    func status(withReply: @escaping @Sendable (Data) -> Void)
    func stop(withReply: @escaping @Sendable (Data) -> Void)
    /// Nollie Link: a fresh single-use pairing offer for the QR code, which replaces any other.
    func linkOffer(withReply: @escaping @Sendable (Data) -> Void)
    /// Whether the open offer has been used, and the linked devices. Never credentials.
    func linkStatus(withReply: @escaping @Sendable (Data) -> Void)
    func linkCancelOffer(withReply: @escaping @Sendable (Data) -> Void)
    /// Unlinks one device and closes its connections.
    func linkRemove(deviceID: String, withReply: @escaping @Sendable (Data) -> Void)
    /// Gets or updates Cua to the reviewed release, starts it and readies its local computers.
    /// The app asks the person first. Nothing the helper downloads runs before it is verified.
    func cuaSetupStart(withReply: @escaping @Sendable (Data) -> Void)
    func cuaSetupStatus(withReply: @escaping @Sendable (Data) -> Void)
    /// Wakes Cua's background part if Cua is on this Mac. Never installs or opens anything.
    func cuaWake(withReply: @escaping @Sendable (Data) -> Void)
    /// Away from home: the switch, Tailscale on this Mac and a typed-in name. A request
    /// `{"on": Bool?, "host": String?}` changes what it names; `{}` only reads.
    func linkAway(request: Data, withReply: @escaping @Sendable (Data) -> Void)
    /// Remove Nollie: stops Hermes and clears the saved choice, closes the Link door, stops Cua's
    /// background part and deletes this helper's own Keychain items. The app unregisters it next.
    func prepareRemoval(withReply: @escaping @Sendable (Data) -> Void)
}

enum NollieRuntimeIPCError: String, Error, Codable, Sendable {
    case invalidRequest, unavailable, busy, credentialsUnavailable, persistenceUnavailable
    case startFailed, startupTimedOut, cancelled
}

struct NollieRuntimeIPCSnapshot: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case stopped, validating, starting, ready, restarting, failed }
    var phase: Phase = .stopped
    var installationID: UUID?
    var endpoint: URL?
    var restartCount = 0
    var failure: String?
    var enabledInstallationID: UUID?
}

struct NollieRuntimeIPCResponse: Codable, Equatable, Sendable {
    var version = 1
    var snapshot = NollieRuntimeIPCSnapshot()
    var error: NollieRuntimeIPCError?

    func encoded() -> Data {
        // Every member is a finite scalar or a URL created by the supervisor.
        // Keep even an unexpected encoding failure a valid, secret-free response.
        (try? JSONEncoder().encode(self)) ?? Data(#"{"version":1,"snapshot":{"phase":"failed","restartCount":0},"error":"unavailable"}"#.utf8)
    }
}

enum NollieLinkIPCError: String, Error, Codable, Sendable { case unavailable, invalidRequest, notFound, persistenceUnavailable }

/// What the Mac app needs to draw a pairing code. The secret is single-use, lives two
/// minutes and is shown only as a QR code; the pin is public.
struct NollieLinkIPCOffer: Codable, Equatable, Sendable {
    var macName: String
    var pin: String
    var port: Int
    var hosts: [String]
    var tag: String
    var secret: String
    var expiresAt: Date
}

struct NollieLinkIPCDevice: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var linkedAt: Date
    var lastActive: Date?
    /// The phone's away public key (base64url), once it swapped one: away through iCloud. Public.
    var awayKey: String?
}

struct NollieLinkIPCStop: Codable, Equatable, Sendable {
    /// Counts up with each Stop, so the app acts once per press.
    var generation: Int
    /// The linked device's name, as it was linked.
    var device: String
    var at: Date
}

struct NollieLinkIPCResponse: Codable, Equatable, Sendable {
    var version = 1
    var offer: NollieLinkIPCOffer?
    /// The device that used the most recent offer.
    var claimedBy: String?
    var devices: [NollieLinkIPCDevice] = []
    var error: NollieLinkIPCError?
    /// The latest "Stop Nollie on my Mac" from a linked phone, since the helper started.
    var stop: NollieLinkIPCStop?
    /// Away from home, only in answer to `linkAway`.
    var away: NollieLinkIPCAway?

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(self)) ?? Data(#"{"version":1,"devices":[],"error":"unavailable"}"#.utf8)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw NollieLinkIPCError.invalidRequest }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let response = try decoder.decode(Self.self, from: data)
        guard response.version == 1 else { throw NollieLinkIPCError.invalidRequest }
        return response
    }
}
/// Away from home on this Mac: the switch, Tailscale as found, a name the person typed in, and
/// the hosts a linked phone is given now.
struct NollieLinkIPCAway: Codable, Equatable, Sendable {
    var on: Bool
    /// "ready", "stopped" or "missing".
    var tailscale: String
    /// The MagicDNS name Nollie found, and Tailscale's addresses on this Mac.
    var name: String?
    var addresses: [String]
    /// This Mac sends everything through a Tailscale exit node: helpers' computers get no internet
    /// unless the exit relay carries their traffic.
    var exitNode: Bool?
    /// The exit relay, a `NollieExitRelayState` raw value. Nil from an older helper.
    var relay: String?
    var host: String?
    var hosts: [String]
}

/// The exit relay for helpers' computers, as Nollie Runtime last found it.
enum NollieExitRelayState: String, Codable, Sendable {
    /// Not running (the helper is starting or stopping).
    case off
    /// No helper's computer is running; the relay starts with one.
    case idle
    /// Listening: the computers' web traffic leaves from this Mac and follows its VPN or exit node.
    case on
    /// It couldn't listen, or can't reach the internet.
    case failed

    /// The relay carries the computers' traffic, or will as soon as one runs: no card needed.
    var carries: Bool { self == .on || self == .idle }

    /// For an exit node: whether to show the card, from a state the helper sent (nil: older helper).
    static func showsExitNodeCard(exitNode: Bool, relay: String?) -> Bool {
        exitNode && !(relay.flatMap(Self.init(rawValue:))?.carries ?? false)
    }
}

/// `RuntimeService/exit-relay.json`, read by the computer add-on. No address, host or count.
struct NollieExitRelayRecord: Codable, Equatable, Sendable {
    static let fileName = "exit-relay.json"
    var version = 1
    var state: NollieExitRelayState
    var port: Int
}

struct NollieLinkIPCAwayRequest: Codable, Equatable, Sendable {
    var on: Bool?
    var host: String?
    /// The Mac app's away public key (base64url), for the door to hand linked phones.
    var sealKey: String?

    static func decode(_ data: Data) -> Self? {
        guard data.count <= 1024 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Where the automatic Cua setup is. Failures are plain words for the person.
struct NollieCuaSetupResponse: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case idle, checking, downloading, installing, starting, preparing, done, needsQuit, failed, unavailable }
    var version = 1
    var phase: Phase = .idle
    var fraction: Double?
    var installedVersion: String?
    var failure: String?

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data(#"{"version":1,"phase":"failed"}"#.utf8)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_384 else { throw NollieLinkIPCError.invalidRequest }
        let response = try JSONDecoder().decode(Self.self, from: data)
        guard response.version == 1 else { throw NollieLinkIPCError.invalidRequest }
        return response
    }
}

/// What Nollie Runtime made when it put Cua on this Mac itself, kept in Nollie's own
/// `CuaSetup` folder. With no such record, Cua belongs to the person and removing Nollie leaves it.
struct NollieCuaReceipt: Codable, Equatable, Sendable {
    static let fileName = "installed.json"
    var version = 1
    /// The Cua Spaces app Nollie installed, in Nollie's own folder.
    var app: String
    /// `~/.cua`, where Cua keeps its state and computers, wasn't there before Nollie installed Cua.
    /// Cua's public docs describe no way to keep that state elsewhere, so it stays in `~/.cua`.
    var madeCuaHome: Bool
}

/// Where a Cua Spaces app may be: the person's own copy in Applications first, then Nollie's own.
/// Nollie and its add-on call the `cua` tool inside it by full path; there is no link in `~/.local/bin`.
enum NollieCuaPlaces {
    static let appName = "Cua Spaces.app"
    static func folders(home: URL, own: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"), own]
    }
    /// The command-line tool of the copy in use, if any.
    static func cli(home: URL, own: URL, fileManager fm: FileManager = .default) -> URL? {
        for folder in folders(home: home, own: own) {
            let tool = folder.appendingPathComponent(appName).appendingPathComponent("Contents/MacOS/cua")
            if fm.isExecutableFile(atPath: tool.path) { return tool }
        }
        return nil
    }
}

/// `RuntimeService/app-gone.json`: Nollie Runtime found Nollie.app in the Trash or deleted, stopped
/// Hermes and Cua's background part, and left. No data was removed. A reinstalled Nollie reads this
/// and offers to use the setup again or remove it.
struct NollieRuntimeAppGone: Codable, Equatable, Sendable {
    static let fileName = "app-gone.json"
    var version = 1
    var at: Date
    /// Where Nollie Runtime was when it noticed.
    var app: String
}

/// What Nollie Runtime managed before Nollie is removed.
struct NollieRuntimeRemovalResponse: Codable, Equatable, Sendable {
    var version = 1
    var hermesStopped: Bool
    var cuaStopped: Bool
    var keychainCleared: Bool

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data(#"{"version":1,"hermesStopped":false,"cuaStopped":false,"keychainCleared":false}"#.utf8)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw NollieLinkIPCError.invalidRequest }
        let response = try JSONDecoder().decode(Self.self, from: data)
        guard response.version == 1 else { throw NollieLinkIPCError.invalidRequest }
        return response
    }
}
#endif
