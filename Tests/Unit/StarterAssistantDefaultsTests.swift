import Foundation
import Testing
@testable import Nollie

struct StarterAssistantDefaultsTests {
    private func contractData() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "nollie-starter", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test func bundledStarterKeepsIdeasPassiveAndBoundsAuthorizedWork() throws {
        let prepared = try StarterAssistantDefaults.prepare(assistantName: "Nollie")
        let config = try #require(JSONSerialization.jsonObject(with: prepared.configuration) as? [String: Any])
        let board = try #require(config["kanban"] as? [String: Any])
        let approvals = try #require(config["approvals"] as? [String: String])
        #expect(prepared.version == 1)
        #expect(board["auto_decompose"] as? Bool == false)
        #expect(board["max_in_progress"] as? Int == 1)
        #expect(board["max_in_progress_per_profile"] as? Int == 1)
        #expect(board["dispatch_in_gateway"] == nil)
        #expect(board["auto_subscribe_on_create"] == nil)
        #expect(approvals == ["mode": "manual", "cron_mode": "deny", "single_query_mode": "deny", "unattended_mode": "deny"])
        #expect((config["cron"] as? [String: Bool])?["allow_agent_scheduling"] == false)
        #expect((config["delegation"] as? [String: Int])?["max_concurrent_children"] == 1)
        #expect((config["plugins"] as? [String: [String]])?["enabled"] == ["nollie-workflow"])
        let telemetry = try #require(config["telemetry"] as? [String: [String: Bool]])
        #expect(telemetry["shared_metrics"] == ["enabled": false, "send": false])
        #expect(config["model"] == nil)
        #expect(config["mcp_servers"] == nil)
    }

    @Test func assistantNameIsOnlyDataAndCannotChangeConfiguration() throws {
        let data = try contractData()
        let named = try StarterAssistantDefaults.prepare(assistantName: "  Juniper \"\\\nconfig: off  ", data: data)
        let ordinary = try StarterAssistantDefaults.prepare(assistantName: "Nollie", data: data)
        #expect(named.configuration == ordinary.configuration)
        #expect(named.assistantName == "Juniper \"\\ config: off")
        let profile = try JSONDecoder().decode([String: String].self, from: named.profile)
        #expect(profile == ["display_name": named.assistantName])
        let soul = try #require(String(data: named.soul, encoding: .utf8))
        #expect(soul.hasPrefix("# " + named.assistantName + "\n\n"))
        #expect(!soul.contains("{{assistant_name}}"))
        #expect(try StarterAssistantDefaults.prepare(assistantName: " \n ", data: data).assistantName == "Nollie")
    }

    @Test func bundledResearchPolicyRequiresEvidenceWithoutAssumingAHelper() throws {
        let prepared = try StarterAssistantDefaults.prepare(assistantName: "Juniper")
        let soul = try #require(String(data: prepared.soul, encoding: .utf8))
        for boundary in [
            "available search and page tools",
            "Keep the user's constraints, such as direct flights only",
            "do not broaden them without asking",
            "Continue safe retries within the same request without asking whether to continue",
            "stop a repeated failure and explain the specific blocker",
            "already configured, capable helper",
            "without asking again for research already authorized",
            "check the helper's evidence yourself",
            "current checks from stale or cached information",
            "sources and the actual check time",
            "do not present an unverified offer as current",
            "unless you actually invoked it",
            "never bypass a permission or site restriction"
        ] {
            #expect(soul.contains(boundary), "The shipped research instructions must retain this boundary.")
        }
        #expect(!soul.contains("Forager"))
        #expect(!soul.contains("Researcher"))
    }

    @Test func bundledWatchPolicyRequiresIntentEvidenceAndBoundedContinuation() throws {
        let prepared = try StarterAssistantDefaults.prepare(assistantName: "Juniper")
        let soul = try #require(String(data: prepared.soul, encoding: .utf8))
        for boundary in [
            "An explicit request to watch needs recurring checks",
            "a one-off search does not authorize a watch",
            "Check existing jobs first and reuse the task's follow-up",
            "Persist the constraints, comparable baseline, verified changes and last check time",
            "Compare like for like and keep optional alternatives separate",
            "Stop when the user says it is done or no longer needed, or its deadline passes",
            "If scheduling is unavailable, say so",
            "quiet-result contract before delivery",
            "Treat a run's step budget as a checkpoint, not completion",
            "Save verified findings, remaining steps and the next useful action",
            "bounded slices only while making progress",
            "Do not claim a continuation exists until it is scheduled",
            "Keep loop guards; never reset them or repeat a failing step",
            "A budget limit alone is not a question for the user"
        ] {
            #expect(soul.contains(boundary), "The shipped watch instructions must retain this boundary.")
        }
        // Watch instructions do not silently enable scheduling in an unconfigured fresh home.
        let config = try #require(JSONSerialization.jsonObject(with: prepared.configuration) as? [String: Any])
        #expect((config["cron"] as? [String: Bool])?["allow_agent_scheduling"] == false)
    }

    @Test func missingOrMalformedResourceNeverFallsBackToUpstreamDefaults() throws {
        #expect(throws: StarterAssistantDefaults.Failure.unavailable) {
            try StarterAssistantDefaults.prepare(assistantName: "Nollie", resource: nil)
        }
        for data in [Data(), Data("{}".utf8), Data("not json".utf8), Data(repeating: 32, count: 8_193)] {
            #expect(throws: StarterAssistantDefaults.Failure.invalid) {
                try StarterAssistantDefaults.prepare(assistantName: "Nollie", data: data)
            }
        }
    }

    @Test func unsafeOrUnknownContractIsRejected() throws {
        let original = try #require(JSONSerialization.jsonObject(with: contractData()) as? [String: Any])
        var variants: [[String: Any]] = []
        var version = original; version["version"] = 2; variants.append(version)
        var missing = original; missing["config"] = nil; variants.append(missing)
        var extra = original; extra["startup_command"] = "fixture"; variants.append(extra)
        var malformed = original; malformed["soul"] = "No name placeholder"; variants.append(malformed)
        for (section, field, value) in [
            ("kanban", "auto_decompose", true as Any),
            ("kanban", "max_in_progress", 10 as Any),
            ("approvals", "unattended_mode", "approve" as Any),
            ("cron", "allow_agent_scheduling", true as Any),
            ("plugins", "enabled", [] as [String]),
            ("plugins", "enabled", ["nollie-workflow", "another-addon"]),
            ("kanban", "dispatch_in_gateway", false as Any)
        ] {
            var changed = original
            var config = try #require(changed["config"] as? [String: Any])
            var fields = try #require(config[section] as? [String: Any])
            fields[field] = value; config[section] = fields; changed["config"] = config
            variants.append(changed)
        }
        for variant in variants {
            let data = try JSONSerialization.data(withJSONObject: variant)
            #expect(throws: StarterAssistantDefaults.Failure.invalid) {
                try StarterAssistantDefaults.prepare(assistantName: "Nollie", data: data)
            }
        }
    }
}
