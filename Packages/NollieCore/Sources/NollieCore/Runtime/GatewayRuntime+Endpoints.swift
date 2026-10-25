import Foundation

// Finding the gateway when its address can change: an installation the Mac app manages, or a
// Mac this phone is linked to.

extension GatewayRuntime {

    /// Asks the managed installation where it is now and, if that changed, switches to it and
    /// saves the new address.
    func resolveManagedEndpoint() async throws {
        guard let resolver = managedEndpointResolver else { return }
        let generation = managedLifecycleGeneration
        let gateway = try await resolver()
        try Task.checkCancellation()

        let installation = connection.managedInstallationID
        func moved(_ saved: GatewayConnection) -> GatewayConnection? {
            saved.updatingManagedEndpoint(gateway.base, activeConnectionID: store.activeConnectionID,
                                          installationID: installation, enabledInstallationID: installation)
        }
        guard generation == managedLifecycleGeneration, let updated = moved(connection) else { throw SocketError.cancelled }
        guard connection.gateway != gateway else { return }

        connection = updated
        await api.updateGateway(gateway)
        try Task.checkCancellation()
        guard generation == managedLifecycleGeneration, store.activeConnectionID == connection.id else {
            throw SocketError.cancelled
        }
        if let saved = store.connection(id: connection.id), let metadata = moved(saved) {
            store.updateMetadata(metadata)
        }
        restartKanbanSocket()
    }

    /// Finds a linked Mac: at home the address that answered last is tried first, then Bonjour;
    /// away, Tailscale's (see `NollieLinkResolver`). Only a door holding the pinned key counts.
    /// A new address is saved for next time, and the Mac is asked for its current hosts once
    /// it answers.
    func resolveLinkedEndpoint() async throws {
        guard let resolver = linkResolver, let link = connection.linkedMac else { return }
        let generation = managedLifecycleGeneration
        let id = connection.id

        guard let host = await resolver.resolve(link, lastGood: connection.gateway.host) else {
            try Task.checkCancellation()
            let message = "Can't reach \(link.macName). At home, check that it's awake. Away, both need Tailscale."
            linkUnreachable = message
            lastError = message
            throw HermesAPIError.transport(message)
        }
        try Task.checkCancellation()
        guard generation == managedLifecycleGeneration, connection.id == id,
              let gateway = try? link.gateway(host: host),
              let updated = connection.updatingLinkedEndpoint(gateway) else {
            throw SocketError.cancelled
        }

        if let shown = linkUnreachable, lastError == shown { lastError = nil }
        linkUnreachable = nil
        defer { Task { await self.refreshLink() } }
        guard gateway != connection.gateway else { return }

        GatewayTrust.shared.register(pin: link.pin, host: host, port: link.port, owner: connection.id)
        connection = updated
        await api.updateGateway(gateway)
        try Task.checkCancellation()
        guard generation == managedLifecycleGeneration else { throw SocketError.cancelled }
        if let saved = store.connection(id: id), let metadata = saved.updatingLinkedEndpoint(gateway) {
            store.updateMetadata(metadata)
        }
        restartKanbanSocket()
    }

    private func restartKanbanSocket() {
        kanban.stopEvents()
        kanban.startEvents()
    }

    // MARK: Away from home

    /// Asks a linked Mac's door where to find it next time, whether away from home is on, and
    /// whether Tailscale is ready there, and keeps the answer. Nil when it can't be asked.
    @discardableResult
    public func refreshLink() async -> NollieLinkHostsReply? {
        guard !linkRefreshing else { return linkInfo }
        linkRefreshing = true
        defer { linkRefreshing = false }
        return await linkRequest("GET", NollieLinkClient.hostsPath)
    }

    /// Turns away from home on or off at the Mac. The door takes this only from a linked phone,
    /// and with away from home off it only hears one that's at home.
    @discardableResult
    public func setLinkAway(_ on: Bool) async -> NollieLinkHostsReply? {
        await linkRequest("POST", on ? NollieLinkClient.awayOnPath : NollieLinkClient.awayOffPath)
    }

    private func linkRequest(_ method: String, _ path: String) async -> NollieLinkHostsReply? {
        guard connection.linkedMac != nil || linkDemo else { return nil }
        let id = connection.id
        guard let (data, response) = try? await api.raw(method, path, body: nil, authenticated: true, timeout: 8),
              response.statusCode == 200,
              let reply = NollieLinkHostsReply.decode(data),
              connection.id == id else { return nil }

        linkInfo = reply
        guard let link = connection.linkedMac else { return reply }
        let next = link.updating(with: reply)
        guard next != link else { return reply }

        // New places to find the same Mac. Each is trusted by the pin, as the code's address was.
        GatewayTrust.shared.register(next, owner: id)
        connection.linkedMac = next
        if var saved = store.connection(id: id), saved.linkedMac?.pin == next.pin {
            saved.linkedMac = next
            store.updateMetadata(saved)
        }
        return reply
    }
}
