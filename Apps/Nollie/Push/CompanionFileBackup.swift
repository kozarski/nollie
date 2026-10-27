import CryptoKit
import Foundation

/// A private, verified copy of only the companion files an installation replaces.
enum CompanionFileBackup {
    struct Entry: Codable, Equatable {
        var path: String
        var copy: String
        var sha256: String
    }
    struct Receipt: Codable {
        var createdAt: Date
        var entries: [Entry]
        var absent: [String]
        var directory: URL
    }
    enum Failure: LocalizedError {
        case unsafePath, unreadable, writeFailed, verificationFailed
        var errorDescription: String? {
            String(localized: "The companion backup could not be verified. No installation files were changed.")
        }
    }

    static func create(paths: [String], parent: URL,
                       read: (String) async throws -> Data?) async throws -> Receipt {
        let fm = FileManager.default
        let folder = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try rejectSymlinkAncestors(parent)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var receipt = Receipt(createdAt: Date(), entries: [], absent: [], directory: folder)
        for (index, path) in paths.enumerated() {
            guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw Failure.unsafePath }
            let data: Data?
            do { data = try await read(path) } catch { throw Failure.unreadable }
            guard let data else { receipt.absent.append(path); continue }
            let name = "\(index)-\(URL(fileURLWithPath: path).lastPathComponent)"
            let output = folder.appendingPathComponent(name)
            guard fm.createFile(atPath: output.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw Failure.writeFailed }
            let sha = hash(data)
            guard hash(try Data(contentsOf: output)) == sha else { throw Failure.verificationFailed }
            receipt.entries.append(Entry(path: path, copy: name, sha256: sha))
        }
        let manifest = try JSONEncoder().encode(receipt)
        let destination = folder.appendingPathComponent("manifest.json")
        guard fm.createFile(atPath: destination.path, contents: manifest, attributes: [.posixPermissions: 0o600]),
              try Data(contentsOf: destination) == manifest else { throw Failure.verificationFailed }
        return receipt
    }

    private static func rejectSymlinkAncestors(_ url: URL) throws {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw Failure.unsafePath }
            current.deleteLastPathComponent()
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
