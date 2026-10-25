import Foundation

// The bots on the gateway: which exist, which one is in front, which one owns a chat, and
// which installation this is.

extension GatewayRuntime {

    // MARK: The default bot

    /// Settings › Bots › Default bot: where the app lands at launch and after chatting with another
    /// bot. Empty means follow the gateway's active profile.
    public static let defaultProfileKey = "bots.defaultProfile"

    /// The chosen default bot, if it is still one of the gateway's.
    public var defaultProfile: String? {
        let chosen = UserDefaults.standard.string(forKey: Self.defaultProfileKey) ?? ""
        let stillThere = profiles.contains { $0.name == chosen }
        return (chosen.isEmpty || !stillThere) ? nil : chosen
    }

    /// If a default bot is chosen and the selection has drifted away from it (say a chat was opened from
    /// a different bot's list, or a notification route led there), switch back.
    public func returnToDefaultProfile() {
        if let wanted = defaultProfile, wanted != selectedProfile { selectedProfile = wanted }
    }

    // MARK: Loading the list

    public func loadProfiles() async {
        let generation = managedLifecycleGeneration
        let reply: ProfilesResponse
        do {
            reply = try await api.get("/api/profiles")
        } catch {
            lastError = error.localizedDescription
            return
        }
        guard !Task.isCancelled, generation == managedLifecycleGeneration else { return }

        profiles = reply.profiles
        followUp(on: reply.profiles.map(\.name), generation: generation)
        await settleSelection()
    }

    /// Work that needn't hold up the list: private bots are kept in step, and the gateway's
    /// identity is learned (unless this runtime was restarted meanwhile).
    private func followUp(on names: [String], generation: UUID) {
        Task { [weak self] in await self?.syncPrivateBots(profiles: names) }
        Task { [weak self] in
            guard let self, self.managedLifecycleGeneration == generation else { return }
            await self.refreshGatewayIdentity()
        }
    }

    /// Picks the bot in front: the default bot if there is one, otherwise whatever is selected
    /// as long as it still exists, otherwise the gateway's active one, its default, or the first.
    private func settleSelection() async {
        if let wanted = defaultProfile, wanted != selectedProfile {
            selectedProfile = wanted
            return
        }
        if let current = selectedProfile, profiles.contains(where: { $0.name == current }) { return }

        let active: ActiveProfileResponse? = try? await api.get("/api/profiles/active")
        let fallback = profiles.first { $0.isDefault == true } ?? profiles.first
        selectedProfile = active?.current ?? fallback?.name
    }

    // MARK: Which installation is this

    /// Learns which installation this is, but only once these credentials have passed a protected
    /// request. The raw installation id never leaves the response decoder or reaches the saved index.
    @discardableResult
    public func refreshGatewayIdentity() async -> String? {
        let generation = managedLifecycleGeneration
        let gateway = connection.gateway
        let unchanged = { [self] in
            !Task.isCancelled && generation == managedLifecycleGeneration && connection.gateway == gateway
        }

        // Status is public on some gateways, so a protected route that returns only metadata
        // proves the credentials first.
        guard (try? await api.get("/api/profiles/active", profile: "default") as ActiveProfileResponse) != nil, unchanged(),
              let status = try? await api.get("/api/status", profile: "default") as GatewayStatusResponse, unchanged(),
              var saved = store.connection(id: connection.id), saved.gateway == gateway else { return nil }

        let identity = status.installId.flatMap { GatewayIdentity.fingerprint(installID: $0) }
        connection.gatewayIdentity = identity
        if saved.gatewayIdentity != identity {
            saved.gatewayIdentity = identity
            store.updateMetadata(saved)
        }
        return identity
    }

    // MARK: Who owns a chat

    /// How one bot's store answered a question about a chat.
    private enum Standing {
        case none
        case live
        case archived
        case failed(Error)
    }

    private func standing(of id: String, under bot: String) async -> Standing {
        do {
            let row: JSONValue = try await api.get("/api/sessions/\(id)", profile: bot)
            let flag = row["archived"]
            return (flag?.boolValue ?? ((flag?.doubleValue ?? 0) != 0)) ? .archived : .live
        } catch HermesAPIError.http(let status, _) where status == 404 {
            return .none
        } catch {
            return .failed(error)
        }
    }

    /// Finds the bot whose store holds a given chat, for opens that carry no bot (a notification
    /// without one, a card pointing at a chat created elsewhere). Starts with the selected bot and stops
    /// at the first live hit. Nil means nobody has it yet, as happens when the chat is a few seconds
    /// old. Throws when the gateway cannot answer, since a guess is what ends up moving chats.
    public func ownerProfile(ofStored id: String) async throws -> String? {
        await loadProfilesIfNeeded()
        let (holders, trouble) = await askStores(about: id)
        if let owner = Self.owner(among: holders) { return owner }
        if let trouble { throw trouble }
        return selectedProfile
    }

    private func loadProfilesIfNeeded() async {
        guard profiles.isEmpty else { return }
        await loadProfiles()
    }

    /// A bot's name and whether its copy of a chat is archived.
    public typealias Holder = (name: String, archived: Bool)

    /// Asks each bot's store in turn, stopping at the first live copy. Failures don't stop the
    /// search; the last one is handed back in case nothing else answers.
    private func askStores(about id: String) async -> (holders: [(name: String, archived: Bool)], trouble: Error?) {
        var holders: [(name: String, archived: Bool)] = []
        var trouble: Error?
        let order = Self.lookupOrder(profiles: profiles.map(\.name), selected: selectedProfile)
        for bot in order {
            let answer = await standing(of: id, under: bot)
            if case .failed(let error) = answer { trouble = error }
            if case .archived = answer { holders.append((bot, true)) }
            if case .live = answer {
                holders.append((bot, false))
                break
            }
        }
        return (holders, trouble)
    }

    /// Order to search in: the selected bot leads, since it most likely holds the chat, and the others
    /// follow in the order the gateway lists them.
    public nonisolated static func lookupOrder(profiles: [String], selected: String?) -> [String] {
        var ordered = profiles
        if let selected, let at = ordered.firstIndex(of: selected) {
            ordered.remove(at: at)
            ordered.insert(selected, at: 0)
        }
        return ordered
    }

    /// Choose the live holder over an archived one. A chat the gateway relocates leaves its id behind as
    /// an archived row in the old store.
    public nonisolated static func owner(among found: [Holder]) -> String? {
        (found.first { !$0.archived } ?? found.first)?.name
    }
}
