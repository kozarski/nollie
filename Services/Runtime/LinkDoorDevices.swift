#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Security

/// The phones linked to this Mac and the single pairing offer that may be open at a time.
/// Device credentials are stored only as SHA-256 hashes; the offer secret only in memory.
final class LinkDoorDevices: @unchecked Sendable {
    struct Device: Codable, Equatable, Sendable {
        let id: UUID
        var name: String
        let credentialHash: Data
        let linkedAt: Date
        var lastActive: Date?
        /// Someone at home a helper was shared with. Nil for an owner: every device linked before
        /// sharing existed, and every one linked with an ordinary code.
        var member: Member?
    }

    /// What a member may reach: the helpers shared with them and the chats they started.
    struct Member: Codable, Equatable, Sendable {
        /// The name the owner typed ("Sam"), shown on the owner's asks.
        var person: String
        var helpers: [String]
        /// "Small yeses": they may say Allow once to their own asks of a small kind. Off unless the owner turns it on.
        var small = false
        /// Chats they started, newest last, at most `maximumChats`.
        var chats: [Chat] = []
    }

    struct Chat: Codable, Hashable, Sendable {
        /// The stored session id.
        let id: String
        let profile: String
    }

    /// A code made for someone at home: whoever claims it becomes a member with these helpers.
    struct Invite: Equatable, Sendable {
        let person: String
        let helpers: [String]
    }

    /// Everything kept on disk: the port chosen once, the Bonjour tag and the device hashes.
    struct State: Codable, Equatable, Sendable {
        var version = 1
        var port: Int?
        var installTag: String
        var devices: [Device] = []
        /// Away from home: tailnet hosts offered and tailnet sources let in. Off for a new install;
        /// a state file from before this setting, with a phone already linked, keeps it on.
        var away: Bool?
        /// A Tailscale name or address the person typed in, for when Nollie can't find it.
        var awayHost: String?
    }

    struct Offer: Equatable, Sendable {
        let secret: Data
        let expiresAt: Date
        var invite: Invite? = nil
    }

    enum OfferState: Equatable, Sendable {
        case none
        case open(expiresAt: Date)
        case claimed(deviceID: UUID, name: String)
    }

    enum ClaimFailure: Error, Equatable, Sendable { case noOffer, expired, mismatch, invalidName, full, unsaved }

    static let offerLifetime: TimeInterval = 120
    static let maximumDevices = 16
    static let maximumChats = 500

    private let lock = NSLock()
    private let store: any LinkDoorStateStoring
    private var state: State
    private var offer: Offer?
    private var lastClaim: (offerSecret: Data, deviceID: UUID, name: String)?
    private var lastSavedActivity: [UUID: Date] = [:]

    init(store: any LinkDoorStateStoring) throws {
        self.store = store
        if let saved = try store.load() {
            guard saved.version == 1, Self.validTag(saved.installTag) else { throw LinkDoorStateError.invalid }
            state = saved
            if saved.away == nil {
                // Decided once: phones linked before this setting keep working where they did.
                state.away = !saved.devices.isEmpty
                try? store.save(state)
            }
        } else {
            state = State(installTag: Self.randomHex(8), away: false)
            try store.save(state)
        }
    }

    // MARK: Away from home

    var away: Bool { locked { state.away ?? false } }
    var awayHost: String? { locked { state.awayHost } }

    func setAway(_ on: Bool, host: String?? = .none) throws {
        try locked {
            var next = state
            next.away = on
            if case .some(let typed) = host { next.awayHost = typed }
            guard next != state else { return }
            try store.save(next)
            state = next
        }
    }

    var installTag: String { locked { state.installTag } }
    var port: Int? { locked { state.port } }
    var devices: [Device] { locked { state.devices } }
    var hasDevices: Bool { locked { !state.devices.isEmpty } }

    func savePort(_ port: Int) throws {
        try locked {
            guard state.port != port else { return }
            var next = state
            next.port = port
            try store.save(next)
            state = next
        }
    }

    // MARK: Offers

    /// A fresh single-use secret, replacing any offer still open. With an invite, whoever claims it
    /// becomes a member; without one, an owner.
    func makeOffer(now: Date = Date(), invite: Invite? = nil) -> Offer {
        locked {
            let made = Offer(secret: Self.randomBytes(32), expiresAt: now.addingTimeInterval(Self.offerLifetime), invite: invite)
            offer = made
            lastClaim = nil
            return made
        }
    }

    func cancelOffer() { locked { offer = nil; lastClaim = nil } }

    func offerState(now: Date = Date()) -> OfferState {
        locked {
            if let lastClaim { return .claimed(deviceID: lastClaim.deviceID, name: lastClaim.name) }
            guard let offer, offer.expiresAt > now else { return .none }
            return .open(expiresAt: offer.expiresAt)
        }
    }

    var hasOpenOffer: Bool { if case .open = offerState() { true } else { false } }

    /// Spends the open offer when the secret matches, and returns a new device credential.
    /// A wrong secret leaves the offer open: nobody else can guess 256 bits in two minutes.
    func claim(secret: Data, name rawName: String, now: Date = Date()) throws(ClaimFailure) -> (device: Device, credential: String) {
        lock.lock(); defer { lock.unlock() }
        guard let current = offer else { throw .noOffer }
        guard current.expiresAt > now else { offer = nil; throw .expired }
        guard secret.count == 32, Self.constantTimeEqual(secret, current.secret) else { throw .mismatch }
        guard let name = Self.cleanName(rawName) else { throw .invalidName }
        guard state.devices.count < Self.maximumDevices else { throw .full }
        let credential = Self.randomBytes(32)
        let member = current.invite.map { Member(person: $0.person, helpers: $0.helpers) }
        let device = Device(id: UUID(), name: name, credentialHash: Data(SHA256.hash(data: credential)), linkedAt: now,
                            lastActive: now, member: member)
        var next = state
        next.devices.append(device)
        do { try store.save(next) } catch { throw .unsaved }
        state = next
        offer = nil
        lastClaim = (current.secret, device.id, name)
        return (device, credential.map { String(format: "%02x", $0) }.joined())
    }

    // MARK: Devices

    /// The linked device holding this credential. Every stored hash is compared in full, so
    /// timing reveals neither which device matched nor how much of a guess was right.
    func authenticate(_ presented: String) -> UUID? {
        guard let bytes = Self.hexBytes(presented), bytes.count == 32 else { return nil }
        let hash = Data(SHA256.hash(data: bytes))
        return locked {
            var match: UUID?
            for device in state.devices where Self.constantTimeEqual(hash, device.credentialHash) { match = device.id }
            return match
        }
    }

    func contains(_ id: UUID) -> Bool { locked { state.devices.contains { $0.id == id } } }

    @discardableResult
    func remove(_ id: UUID) throws -> Bool {
        try locked {
            guard state.devices.contains(where: { $0.id == id }) else { return false }
            var next = state
            next.devices.removeAll { $0.id == id }
            try store.save(next)
            state = next
            lastSavedActivity[id] = nil
            if lastClaim?.deviceID == id { lastClaim = nil }
            return true
        }
    }

    // MARK: Members

    /// The member record of a linked device, or nil for an owner (or a device no longer linked).
    func member(_ id: UUID) -> Member? { locked { state.devices.first { $0.id == id }?.member } }

    var members: [Device] { locked { state.devices.filter { $0.member != nil } } }

    /// Changes what a member may reach. Their chats with a helper no longer shared are forgotten.
    @discardableResult
    func updateMember(_ id: UUID, helpers: [String]? = nil, small: Bool? = nil) throws -> Bool {
        try locked {
            guard let index = state.devices.firstIndex(where: { $0.id == id }), var member = state.devices[index].member else { return false }
            if let helpers {
                member.helpers = helpers
                member.chats.removeAll { !helpers.contains($0.profile) }
            }
            if let small { member.small = small }
            var next = state
            next.devices[index].member = member
            guard next != state else { return true }
            try store.save(next)
            state = next
            return true
        }
    }

    /// Notes a chat a member started (or a chat's new stored id), so it can be opened again.
    func addChat(_ chat: Chat, for id: UUID) {
        locked {
            guard let index = state.devices.firstIndex(where: { $0.id == id }), var member = state.devices[index].member,
                  !member.chats.contains(chat) else { return }
            member.chats.append(chat)
            if member.chats.count > Self.maximumChats { member.chats.removeFirst(member.chats.count - Self.maximumChats) }
            var next = state
            next.devices[index].member = member
            guard (try? store.save(next)) != nil else { return }
            state = next
        }
    }

    /// Notes use; written to disk at most once a minute per device.
    func touch(_ id: UUID, now: Date = Date()) {
        locked {
            guard let index = state.devices.firstIndex(where: { $0.id == id }) else { return }
            state.devices[index].lastActive = now
            if let saved = lastSavedActivity[id], now.timeIntervalSince(saved) < 60 { return }
            lastSavedActivity[id] = now
            try? store.save(state)
        }
    }

    // MARK: Helpers

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<a.count { difference |= a[a.startIndex + index] ^ b[b.startIndex + index] }
        return difference == 0
    }

    static func cleanName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{200E}\u{200F}"))
        guard !name.isEmpty, name.count <= 64, !name.unicodeScalars.contains(where: hidden.contains) else { return nil }
        return name
    }

    static func validTag(_ tag: String) -> Bool {
        tag.utf8.count == 16 && tag.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return Data(bytes)
    }

    static func randomHex(_ count: Int) -> String { randomBytes(count).map { String(format: "%02x", $0) }.joined() }

    static func hexBytes(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard bytes.count % 2 == 0, bytes.count <= 128 else { return nil }
        var out = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }
    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 97...102: byte - 87
        default: nil
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

enum LinkDoorStateError: Error, Equatable { case invalid, unavailable }

protocol LinkDoorStateStoring: Sendable {
    func load() throws -> LinkDoorDevices.State?
    func save(_ state: LinkDoorDevices.State) throws
}

/// Keeps the state for tests and previews.
final class LinkDoorMemoryState: LinkDoorStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: LinkDoorDevices.State?
    var failSaves = false
    init(_ state: LinkDoorDevices.State? = nil) { saved = state }
    var current: LinkDoorDevices.State? { lock.lock(); defer { lock.unlock() }; return saved }
    func load() throws -> LinkDoorDevices.State? { lock.lock(); defer { lock.unlock() }; return saved }
    func save(_ state: LinkDoorDevices.State) throws {
        lock.lock(); defer { lock.unlock() }
        if failSaves { throw LinkDoorStateError.unavailable }
        saved = state
    }
}

/// `link.json` in a private directory owned by this user: mode 0600, written atomically,
/// never followed through a link and refused when shared or oversized.
struct LinkDoorStateFile: LinkDoorStateStoring {
    let directory: URL
    private let name = "link.json"
    private static let maximumSize = 256 * 1024

    func load() throws -> LinkDoorDevices.State? {
        guard let fd = try openDirectory(create: false) else { return nil }
        defer { close(fd) }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0 {
            guard errno == ENOENT else { throw LinkDoorStateError.unavailable }
            return nil
        }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_nlink == 1, info.st_size <= Self.maximumSize else { throw LinkDoorStateError.unavailable }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size) + 1)
        let count = read(file, &bytes, bytes.count)
        guard count == Int(info.st_size) else { throw LinkDoorStateError.unavailable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let state = try? decoder.decode(LinkDoorDevices.State.self, from: Data(bytes.prefix(count))) else { throw LinkDoorStateError.invalid }
        return state
    }

    func save(_ state: LinkDoorDevices.State) throws {
        guard let fd = try openDirectory(create: true) else { throw LinkDoorStateError.unavailable }
        defer { close(fd) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(state)
        let temp = ".link-" + UUID().uuidString
        let file = openat(fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw LinkDoorStateError.unavailable }
        defer { close(file); unlinkat(fd, temp, 0) }
        let written = data.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(file) == 0, renameat(fd, temp, fd, name) == 0, fsync(fd) == 0 else {
            throw LinkDoorStateError.unavailable
        }
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT, create else {
                if errno == ENOENT { return nil }
                throw LinkDoorStateError.unavailable
            }
            guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { throw LinkDoorStateError.unavailable }
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LinkDoorStateError.unavailable }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd); throw LinkDoorStateError.unavailable
        }
        return fd
    }
}
#endif
