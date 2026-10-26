import Foundation

// What the app tells the gateway about itself on connecting, and what it checks in return.

extension GatewayRuntime {

    /// Declares that this socket can answer server requests (approval, clarify and so on). Skipping
    /// this leaves the agent waiting with no card on screen, since the gateway then never writes an
    /// approval frame. The reply lists what the gateway will send; if "approval" is absent, ask once more.
    public func advertiseCapabilities() async {
        for attempt in 1...2 {
            guard let granted = await offerServerRequests() else {
                log.warning("client.capabilities got no reply on try \(attempt)")
                continue
            }
            serverRequestsAdvertised = granted
            log.info("client.capabilities → \(granted.joined(separator: ","), privacy: .public)")
            if granted.contains("approval") { break }
        }
    }

    private func offerServerRequests() async -> [String]? {
        let reply = try? await socket.call("client.capabilities", params: ["server_requests": true], timeout: 15)
        return reply.map { ($0["server_requests"]?.arrayValue ?? []).compactMap(\.stringValue) }
    }

    /// Everything to do once the socket is up: capabilities, the bot's home, projects, the
    /// kanban plugin, push registration, and the version check.
    public func refreshCapabilities() async {
        guard socketEnabled else { return }
        do {
            try await socket.waitUntilReady()
        } catch {
            log.warning("capabilities: \(error.localizedDescription, privacy: .public)")
            return
        }
        await advertiseCapabilities()
        await learnProfileHome()
        await refreshPlugins()
        await pushRegistrar?.syncRegistration(runtime: self)
        await probeCodeSkew()
    }

    /// The two pieces that live in plugins on the gateway: projects and the board.
    private func refreshPlugins() async {
        await projects.refresh()
        await kanban.probe()
    }

    func learnProfileHome() async {
        // Asked of the bot selected now, and kept only if it still is: the answer for another bot would
        // point this one's files at the wrong folder.
        let bot = selectedProfile
        let asked = Self.params(["key": "profile"], owner: bot)
        guard let config = try? await call("config.get", asked, 120), selectedProfile == bot else { return }
        profileHome = config["home"]?.stringValue
    }

    /// A single cheap GET. Only a 503 "restart required" reply sets the flag; any other result clears it.
    public func probeCodeSkew() async {
        restartRequired = await staleCodeNotice()
    }

    private func staleCodeNotice() async -> String? {
        do {
            let _: JSONValue = try await api.get("/api/model/options", profile: selectedProfile)
            return nil
        } catch HermesAPIError.http(let status, let detail) where status == 503 {
            return MaintenanceModel.isRestartRequired(detail) ? detail : nil
        } catch {
            return nil
        }
    }
}
