import Foundation

/// Keep skills as they are: one switch per helper so it can't rewrite its own skills. It can still use them.
///
/// Hermes 0.23 locks one skill at a time (`PUT /api/skills/lock?profile=`, the same record as `hermes curator lock`),
/// and has no switch for all of a helper's skills. So the switch is the workflow add-on's
/// (`GET/PUT /api/plugins/nollie-workflow/keep-skills`), which locks each skill the helper makes from then on, and the
/// app locks the skills it already has, or unlocks them all when the switch goes off. A skill the helper writes as
/// plain files, past its skill tool, is locked the next time the Mac opens this switch.
public enum KeepSkills {
    public static let path = "/api/plugins/nollie-workflow/keep-skills"
    public static let lockPath = "/api/skills/lock"

    public struct Switch: Decodable, Equatable, Sendable {
        public var bot: String
        public var on: Bool
    }

    /// The helper's switch, or nil when the add-on has no such route (an older add-on, or a gateway without it).
    public static func load(bot: String, api: HermesAPI) async throws -> Bool? {
        do {
            let found: Switch = try await api.get(path, query: [URLQueryItem(name: "bot", value: bot)])
            return found.bot == bot ? found.on : nil
        } catch HermesAPIError.http(let status, _) where status == 404 {
            return nil
        }
    }

    public static func save(bot: String, on: Bool, api: HermesAPI) async throws -> Bool {
        let saved: Switch = try await api.send("PUT", path, json: ["bot": .string(bot), "on": .bool(on)])
        return saved.on
    }

    /// The skills whose lock has to change for the switch to hold: on locks every one not yet locked, off unlocks
    /// every locked one.
    public static func changes(_ skills: [SkillInfo], on: Bool) -> [String] {
        skills.filter { ($0.locked ?? false) != on }.map(\.name)
    }

    /// Turns the switch, then puts every skill the helper has as it says. True when all of it went through; a skill
    /// that has gone meanwhile (404) doesn't count against it.
    public static func set(_ on: Bool, bot: String, api: HermesAPI) async -> Bool {
        guard (try? await save(bot: bot, on: on, api: api)) == on else { return false }
        return await settle(on, bot: bot, api: api)
    }

    /// Locks (or unlocks) each skill that doesn't match the switch yet.
    public static func settle(_ on: Bool, bot: String, api: HermesAPI) async -> Bool {
        guard let skills: [SkillInfo] = try? await api.get("/api/skills", profile: bot) else { return false }
        var allWent = true
        for name in changes(skills, on: on) {
            do {
                let _: JSONValue = try await api.send("PUT", lockPath, profile: bot, json: ["name": .string(name), "locked": .bool(on)])
            } catch HermesAPIError.http(let status, _) where status == 404 {
                continue
            } catch {
                allWent = false
            }
        }
        return allWent
    }
}
