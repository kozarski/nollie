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
        /// The phone's away public key (X25519), swapped over this link for iCloud's sealed mailbox.
        var awayKey: Data?
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
        /// The Mac app's away public key, given over XPC. Its private half stays in the app's Keychain.
        var awayMacKey: Data?
    }

    struct Offer: Equatable, Sendable {
        let secret: Data
        let expiresAt: Date
    }

    enum OfferState: Equatable, Sendable {
        case none
        case open(expiresAt: Date)
        case claimed(deviceID: UUID, name: String)
    }

    enum ClaimFailure: Error, Equatable, Sendable { case noOffer, expired, mismatch, invalidName, full, unsaved }

    static let offerLifetime: TimeInterval = 120
    static let maximumDevices = 16

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

    // MARK: Away through iCloud

    var awayMacKey: Data? { locked { state.awayMacKey } }

    /// The Mac app's away public key. A new one means the phones' keys were swapped with the old
    /// one, so theirs are forgotten and each swaps again at home.
    func setAwayMacKey(_ key: Data) throws {
        try locked {
            guard key.count == 32, state.awayMacKey != key else { return }
            var next = state
            next.awayMacKey = key
            for index in next.devices.indices { next.devices[index].awayKey = nil }
            try store.save(next)
            state = next
        }
    }

    /// Keeps a linked phone's away public key. False when the device is gone.
    func setAwayKey(_ key: Data, for id: UUID) throws -> Bool {
        try locked {
            guard key.count == 32, let index = state.devices.firstIndex(where: { $0.id == id }) else { return false }
            guard state.devices[index].awayKey != key else { return true }
            var next = state
            next.devices[index].awayKey = key
            try store.save(next)
            state = next
            return true
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

    /// A fresh single-use secret, replacing any offer still open.
    func makeOffer(now: Date = Date()) -> Offer {
        locked {
            let made = Offer(secret: Self.randomBytes(32), expiresAt: now.addingTimeInterval(Self.offerLifetime))
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
        let device = Device(id: UUID(), name: name, credentialHash: Data(SHA256.hash(data: credential)), linkedAt: now, lastActive: now)
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
