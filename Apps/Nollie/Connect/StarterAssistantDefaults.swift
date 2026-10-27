import Foundation

/// A versioned starter for newly created homes. Loading it never writes to a home.
enum StarterAssistantDefaults {
    struct Prepared: Sendable {
        let version: Int
        let assistantName: String
        let configuration: Data
        let soul: Data
        let profile: Data
    }

    enum Failure: LocalizedError, Equatable {
        case unavailable, invalid

        var errorDescription: String? {
            String(localized: "The starter settings are missing or incomplete in this build. Nothing was created.")
        }
    }

    static func prepare(assistantName: String, bundle: Bundle = .main) throws -> Prepared {
        try prepare(assistantName: assistantName,
                    resource: bundle.url(forResource: "nollie-starter", withExtension: "json"))
    }

    static func prepare(assistantName: String, resource: URL?) throws -> Prepared {
        guard let resource else { throw Failure.unavailable }
        do {
            let values = try resource.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, (1...8_192).contains(size) else {
                throw Failure.invalid
            }
            return try prepare(assistantName: assistantName, data: Data(contentsOf: resource))
        } catch let failure as Failure { throw failure }
        catch { throw Failure.unavailable }
    }

    static func prepare(assistantName: String, data: Data) throws -> Prepared {
        do {
            guard (1...8_192).contains(data.count) else { throw Failure.invalid }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let contract = try decoder.decode(Contract.self, from: data)
            guard contract.version == 1, contract.config.isSafeStarter,
                  contract.soul.hasPrefix("# {{assistant_name}}\n"),
                  contract.soul.components(separatedBy: "{{assistant_name}}").count == 2,
                  (1...4_096).contains(contract.soul.utf8.count) else { throw Failure.invalid }
            let collapsed = assistantName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let name = collapsed.isEmpty ? "Nollie" : collapsed
            guard name.utf8.count <= 256,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw Failure.invalid
            }
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let configuration = try encoder.encode(contract.config)
            let original = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let decodedConfiguration = try JSONSerialization.jsonObject(with: configuration) as? NSDictionary
            guard let original, Set(original.keys) == ["version", "soul", "config"],
                  let rawConfiguration = original["config"] as? NSDictionary,
                  rawConfiguration == decodedConfiguration else { throw Failure.invalid }
            // JSON is valid YAML. The name is encoded as a value, never interpolated into configuration.
            return try Prepared(version: contract.version, assistantName: name,
                                configuration: configuration,
                                soul: Data(contract.soul.replacingOccurrences(of: "{{assistant_name}}", with: name).utf8),
                                profile: encoder.encode(["display_name": name]))
        } catch { throw Failure.invalid }
    }

    private struct Contract: Decodable {
        let version: Int
        let soul: String
        let config: Configuration
    }

    private struct Configuration: Codable {
        struct Approvals: Codable {
            let mode, cronMode, singleQueryMode, unattendedMode: String
        }
        struct Kanban: Codable {
            let autoDecompose: Bool
            let maxInProgress, maxInProgressPerProfile: Int
        }
        struct Delegation: Codable { let maxConcurrentChildren: Int }
        struct Cron: Codable { let allowAgentScheduling: Bool }
        struct Plugins: Codable { let enabled: [String] }
        struct Telemetry: Codable {
            struct Metrics: Codable { let enabled, send: Bool }
            let sharedMetrics: Metrics
        }

        let approvals: Approvals
        let kanban: Kanban
        let delegation: Delegation
        let cron: Cron
        let plugins: Plugins
        let telemetry: Telemetry

        // Version 1 must retain these boundaries even if a bundled resource is incomplete or edited.
        var isSafeStarter: Bool {
            approvals.mode == "manual" && approvals.cronMode == "deny"
                && approvals.singleQueryMode == "deny" && approvals.unattendedMode == "deny"
                && !kanban.autoDecompose && kanban.maxInProgress == 1 && kanban.maxInProgressPerProfile == 1
                && delegation.maxConcurrentChildren == 1 && !cron.allowAgentScheduling
                && plugins.enabled == ["nollie-workflow"]
                && !telemetry.sharedMetrics.enabled && !telemetry.sharedMetrics.send
        }
    }
}
