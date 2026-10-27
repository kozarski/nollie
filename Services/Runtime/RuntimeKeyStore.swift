#if os(macOS)
import Foundation
import Darwin
#if NOLLIE_DIRECT
import Security
import LocalAuthentication
#endif

/// API keys and tokens for the assistant Nollie runs on this Mac. They are kept in this helper's
/// Keychain, never in Hermes's `.env` files, and reach Hermes only as it starts: each process reads
/// them once from a private pipe (`runtime_entry.py`). Values are never logged, printed or sent
/// over IPC; only counts leave this file.
struct RuntimeKey: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let profile: String
    let name: String
    let value: String

    /// Names only, so a key never lands in a log or a test failure by accident.
    var description: String { "\(profile)/\(name)" }
    var debugDescription: String { description }
}

protocol RuntimeKeyStoring: Sendable {
    /// Every key kept for one installation.
    func keys(for installationID: UUID) throws -> [RuntimeKey]
    /// Adds or replaces one key, and reads it back before returning.
    func save(_ key: RuntimeKey, for installationID: UUID) throws
    func delete(profile: String, name: String, for installationID: UUID) throws
    /// Installations with keys kept, so the ones whose setup is gone can be forgotten.
    func installations() throws -> Set<UUID>
}

enum RuntimeKeyError: Error, Equatable { case keychain(Int32), mismatch, invalid }

/// Which `.env` entries are keys. Hermes treats these suffixes as credentials (`env_loader.py`,
/// `secret_sources/registry.py`). Settings Hermes reads only process-wide (`secret_scope.py`'s
/// global names) and the session token Nollie gives each start stay where they are.
enum RuntimeKeyNames {
    private static let suffixes = ["_KEY", "_TOKEN", "_SECRET", "_PASSWORD"]
    private static let processWide = ["HERMES_KANBAN_", "HERMES_TELEGRAM_", "TERMINAL_", "NOLLIE_"]
    private static let minted: Set<String> = ["HERMES_DASHBOARD_SESSION_TOKEN"]

    static func isKey(_ name: String) -> Bool {
        isEnvName(name) && suffixes.contains { name.hasSuffix($0) }
            && !processWide.contains { name.hasPrefix($0) } && !minted.contains(name)
    }

    static func isEnvName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, (1...128).contains(bytes.count), first == 95 || isLetter(first) else { return false }
        return bytes.allSatisfy { $0 == 95 || isLetter($0) || (48...57).contains($0) }
    }

    /// `default`, or a Hermes profile id (`hermes_constants.PROFILE_ID_RE`).
    static func isProfile(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, (1...64).contains(bytes.count), (97...122).contains(first) || (48...57).contains(first) else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
    }

    private static func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
}

#if NOLLIE_DIRECT
/// One generic password per key in this helper's Data Protection Keychain: account
/// `<installation>/<bot>/<NAME>`, this device only, readable after the first unlock, never synced,
/// never prompting.
struct RuntimeKeychainKeys: RuntimeKeyStoring {
    static let service = "com.coreykozarski.nollie.runtime.keys"

    private func query(account: String? = nil) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service,
                                    kSecUseDataProtectionKeychain as String: true,
                                    kSecAttrSynchronizable as String: false,
                                    kSecUseAuthenticationContext as String: context]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private static func account(_ id: UUID, _ profile: String, _ name: String) -> String { "\(id.uuidString)/\(profile)/\(name)" }

    private func accounts() throws -> [(id: UUID, profile: String, name: String)] {
        var lookup = query()
        lookup[kSecMatchLimit as String] = kSecMatchLimitAll
        lookup[kSecReturnAttributes as String] = true
        var items: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = items as? [[String: Any]] else { throw RuntimeKeyError.keychain(status) }
        return rows.compactMap { row in
            let parts = (row[kSecAttrAccount as String] as? String)?.split(separator: "/").map(String.init) ?? []
            guard parts.count == 3, let id = UUID(uuidString: parts[0]), RuntimeKeyNames.isProfile(parts[1]),
                  RuntimeKeyNames.isEnvName(parts[2]) else { return nil }
            return (id, parts[1], parts[2])
        }
    }

    private func value(_ account: String) throws -> String? {
        var lookup = query(account: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw RuntimeKeyError.keychain(status)
        }
        return value
    }

    func keys(for installationID: UUID) throws -> [RuntimeKey] {
        try accounts().filter { $0.id == installationID }.compactMap { entry in
            try value(Self.account(entry.id, entry.profile, entry.name)).map { RuntimeKey(profile: entry.profile, name: entry.name, value: $0) }
        }
    }

    func save(_ key: RuntimeKey, for installationID: UUID) throws {
        guard RuntimeKeyNames.isProfile(key.profile), RuntimeKeyNames.isEnvName(key.name), !key.value.isEmpty else { throw RuntimeKeyError.invalid }
        let account = Self.account(installationID, key.profile, key.name)
        let data = Data(key.value.utf8)
        var status = SecItemUpdate(query(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var record = query(account: account)
            record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            record[kSecValueData as String] = data
            status = SecItemAdd(record as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RuntimeKeyError.keychain(status) }
        guard try value(account) == key.value else { throw RuntimeKeyError.mismatch }
    }

    func delete(profile: String, name: String, for installationID: UUID) throws {
        let status = SecItemDelete(query(account: Self.account(installationID, profile, name)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RuntimeKeyError.keychain(status) }
    }

    func installations() throws -> Set<UUID> { Set(try accounts().map(\.id)) }

    /// Deletes every installation's keys, for Remove Nollie. True when none is left.
    static func forgetAll() -> Bool {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecUseDataProtectionKeychain as String: true] as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
#endif


extension RuntimeKeyStoring {
    /// Forgets the keys of setups whose folder is gone. A folder that can't be checked keeps its keys.
    func forgetRemovedInstallations(in installations: URL, keeping current: UUID) throws -> Int {
        var forgotten = 0
        for id in try self.installations() where id != current {
            var info = stat()
            guard lstat(installations.appendingPathComponent(id.uuidString).path, &info) != 0, errno == ENOENT else { continue }
            for key in try keys(for: id) {
                try delete(profile: key.profile, name: key.name, for: id)
                forgotten += 1
            }
        }
        return forgotten
    }
}
#endif
