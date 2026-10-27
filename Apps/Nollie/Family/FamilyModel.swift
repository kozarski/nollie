import Foundation
import Observation
import NollieCore

/// Sharing a helper at home, as this device sees it: whether it is someone a helper was shared with,
/// and for the owner, who has which helper and what they are waiting on. The Mac's door decides all
/// of it; this only reads its answers and passes the owner's choices on.
@MainActor @Observable
final class FamilyModel {
    /// Who this device is to the Mac, once it has said.
    private(set) var me: NollieFamilyMe?
    /// The owner's view: people and their open asks.
    private(set) var overview = NollieFamilyOverview()
    private(set) var issue: String?
    @ObservationIgnored private var lastOverview = Date.distantPast

    /// The demo copy's `-nollie-demo-family owner|member`, for pictures against the mock gateway.
    static var demoRole: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if DemoMode.isOn, let i = args.firstIndex(of: "-nollie-demo-family"), i + 1 < args.count { return args[i + 1] }
        #endif
        return nil
    }

    /// This device joined as someone at home. Its screens show only what was shared.
    func isMember(_ model: AppModel) -> Bool {
        if let role = Self.demoRole { return role == "member" }
        if model.runtime?.connection.linkedMac?.sharedBy != nil { return true }
        return me?.isMember == true
    }

    /// Who shares with this device, by first name, or "the owner" before the Mac has said.
    func ownerName(_ model: AppModel) -> String {
        let said = me?.owner ?? model.runtime?.connection.linkedMac?.sharedBy ?? ""
        return said.isEmpty ? "the owner" : said
    }

    /// Where sharing can start: the Direct Mac that runs the assistant, or a phone linked to it as
    /// its owner. Never on a member's phone, and never for a Private helper.
    func canShare(_ model: AppModel, profile: String? = nil) -> Bool {
        guard !isMember(model), let runtime = model.runtime else { return false }
        if let profile, runtime.profiles.first(where: { $0.name == profile })?.isPrivateBot(on: runtime.connection.id) == true
            || ["private", "moss"].contains(profile) { return false }
        if Self.demoRole == "owner" { return true }
        #if os(macOS)
        return NollieLinkMacClient.isAvailable(for: runtime.connection)
        #else
        return runtime.connection.linkedMac != nil
        #endif
    }

    // MARK: Reading

    func refreshMe(_ model: AppModel) async {
        guard let runtime = model.runtime, runtime.connection.linkedMac != nil || Self.demoRole != nil else { me = nil; return }
        if let found = try? await NollieFamilyClient.me(runtime.api) { me = found }
    }

    /// The people and their asks, at most every few seconds unless `force`.
    func refreshOverview(_ model: AppModel, force: Bool = false) async {
        guard canShare(model) else { overview = .init(); return }
        guard force || Date().timeIntervalSince(lastOverview) > 2 else { return }
        lastOverview = Date()
        do {
            overview = try await fetchOverview(model)
            issue = nil
        } catch {
            issue = "Couldn't reach your Mac."
        }
    }

    private func fetchOverview(_ model: AppModel) async throws -> NollieFamilyOverview {
        #if os(macOS)
        if usesMacHelper(model) { return Self.overview(from: try await NollieLinkMacClient.family(.init(action: .list))) }
        #endif
        guard let runtime = model.runtime else { throw NollieLinkError.unreachable }
        return try await NollieFamilyClient.overview(runtime.api)
    }

    // MARK: The owner's choices

    /// Makes the household copy of a helper for this person, then a code they scan. The copy has the
    /// helper's look, instructions and skills, and none of its memory or chats.
    func share(_ profile: String, with person: String, model: AppModel) async throws -> NollieLinkOffer {
        guard let runtime = model.runtime else { throw NollieLinkError.unreachable }
        let copy = try await makeCopy(of: profile, for: person, runtime: runtime)
        #if os(macOS)
        if usesMacHelper(model) {
            let response = try await NollieLinkMacClient.family(.init(action: .invite, person: person, helpers: [copy]))
            if let words = response.familyIssue { throw ShareFailure.said(words) }
            guard let made = response.offer, let pin = NollieLinkOffer.decodeBase64URL(made.pin),
                  let secret = NollieLinkOffer.decodeBase64URL(made.secret),
                  let invite = NollieLinkInvite(owner: made.owner ?? "", helpers: made.helpers ?? []) else { throw NollieLinkError.invalidResponse }
            return try NollieLinkOffer(macName: made.macName, pin: pin, port: made.port, hosts: made.hosts, installTag: made.tag,
                                       secret: secret, expiresAt: made.expiresAt, invite: invite)
        }
        #endif
        do {
            return try await NollieFamilyClient.invite(runtime.api, person: person, helpers: [copy])
        } catch HermesAPIError.http(_, let detail) where !detail.isEmpty {
            throw ShareFailure.said(detail)
        }
    }

    /// `career-sam`, made from `career` with Hermes's own copy (config, instructions, skills; no
    /// memory, no chats). A copy that is already there is used again.
    private func makeCopy(of profile: String, for person: String, runtime: GatewayRuntime) async throws -> String {
        let name = NollieFamilyClient.copyName(helper: profile, person: person)
        if runtime.profiles.contains(where: { $0.name == name }) { return name }
        do {
            let _: JSONValue = try await runtime.api.send("POST", "/api/profiles", json: .object([
                "name": .string(name), "clone_from": .string(profile),
                "description": .string("For \(person)"),
            ]))
        } catch HermesAPIError.http(let status, _) where status == 409 {
            return name
        }
        await runtime.loadProfiles()
        return name
    }

    func remove(_ member: NollieFamilyMember, model: AppModel) async {
        do {
            #if os(macOS)
            if usesMacHelper(model), let id = UUID(uuidString: member.id) {
                _ = try await NollieLinkMacClient.remove(id)
                overview = Self.overview(from: try await NollieLinkMacClient.family(.init(action: .list)))
                return
            }
            #endif
            guard let runtime = model.runtime else { return }
            overview = try await NollieFamilyClient.remove(runtime.api, member: member.id)
            issue = nil
        } catch {
            issue = "Couldn't remove \(member.person). Try again."
        }
    }

    /// The owner's Allow once ("once") or Deny ("deny") to an ask. True when Hermes took it.
    @discardableResult
    func answer(_ ask: NollieFamilyAsk, choice: String, model: AppModel) async -> Bool {
        do {
            #if os(macOS)
            if usesMacHelper(model) {
                let response = try await NollieLinkMacClient.family(.init(action: .answer, ask: ask.id, choice: choice))
                if let words = response.familyIssue { issue = words; return false }
                overview = Self.overview(from: response)
                return true
            }
            #endif
            guard let runtime = model.runtime else { return false }
            overview = try await NollieFamilyClient.answer(runtime.api, ask: ask.id, choice: choice)
            issue = nil
            return true
        } catch {
            issue = "Couldn't reach \(ask.person)'s chat. Try again."
            return false
        }
    }

    enum ShareFailure: LocalizedError {
        case said(String)
        var errorDescription: String? { if case .said(let words) = self { words } else { nil } }
    }

    // MARK: The Mac's own helper

    #if os(macOS)
    private func usesMacHelper(_ model: AppModel) -> Bool {
        Self.demoRole == nil && NollieLinkMacClient.isAvailable(for: model.runtime?.connection)
    }

    static func overview(from response: NollieLinkIPCResponse) -> NollieFamilyOverview {
        guard let family = response.family else { return .init() }
        return NollieFamilyOverview(
            members: family.members.map {
                NollieFamilyMember(id: $0.id.uuidString.lowercased(), person: $0.person, device: $0.device, helpers: $0.helpers,
                                   small: $0.small, linkedAt: $0.linkedAt.timeIntervalSince1970,
                                   lastActive: $0.lastActive?.timeIntervalSince1970)
            },
            asks: family.asks.map {
                NollieFamilyAsk(id: $0.id, person: $0.person, helper: $0.helper, chat: $0.chat, small: $0.small,
                                at: $0.at.timeIntervalSince1970,
                                request: (try? JSONDecoder().decode(JSONValue.self, from: $0.request)) ?? .object([:]))
            })
    }
    #endif
}
