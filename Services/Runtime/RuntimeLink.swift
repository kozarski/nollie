#if os(macOS)
import Darwin
import Foundation
import SystemConfiguration

/// Connects the Nollie Link door to the runtime service and to the signed app's requests.
/// Only the Direct edition opens the door.
actor RuntimeLink {
    let door: LinkDoor
    private var expiry: Task<Void, Never>?
    private let detector: TailscaleDetector
    private var tailscale: (status: TailscaleStatus, at: Date)?
    /// The exit relay for helpers' computers, shown beside the exit node.
    private let relay: RuntimeExitRelay?

    init(door: LinkDoor, detector: TailscaleDetector = TailscaleDetector(), relay: RuntimeExitRelay? = nil) {
        self.door = door
        self.detector = detector
        self.relay = relay
    }

    /// The door for this helper, or nil when its identity or saved state can't be used.
    static func make(service: RuntimeService, directory: URL, relay: RuntimeExitRelay? = nil) -> RuntimeLink? {
        #if NOLLIE_DIRECT
        guard let identity = try? LinkDoorIdentity.loadOrCreate(),
              let devices = try? LinkDoorDevices(store: LinkDoorStateFile(directory: directory)) else { return nil }
        let door = LinkDoor(configuration: .init(name: macName(), liveProvider: LiveRelay.start(), owner: ownerName()), identity: identity, devices: devices) {
            guard let upstream = await service.linkUpstream() else { return nil }
            return LinkDoor.Upstream(port: upstream.port, token: upstream.token)
        }
        let link = RuntimeLink(door: door, relay: relay)
        door.hostsProvider = { [weak link] in
            guard let link else { return ([], "missing") }
            return await link.phoneHosts()
        }
        return link
        #else
        return nil
        #endif
    }

    /// Listens again after a helper restart when a device is linked.
    func resume() async { try? await door.refresh() }

    /// Stops listening and closes every connection, for good (Nollie is being removed or is gone).
    func close() { expiry?.cancel(); door.stop() }

    func offer() async -> NollieLinkIPCResponse {
        let made = door.devices.makeOffer()
        do { try await door.start() } catch {
            door.devices.cancelOffer()
            return response(error: .unavailable)
        }
        guard let port = door.port else { return response(error: .unavailable) }
        scheduleExpiry(at: made.expiresAt)
        var result = response()
        result.offer = NollieLinkIPCOffer(macName: door.configuration.name, pin: LinkDoorBase64URL.encode(door.identity.pin),
                                          port: Int(port), hosts: await hosts(forCode: true), tag: door.devices.installTag,
                                          secret: LinkDoorBase64URL.encode(made.secret), expiresAt: made.expiresAt)
        return result
    }

    func status() -> NollieLinkIPCResponse { response() }

    func cancelOffer() async -> NollieLinkIPCResponse {
        door.devices.cancelOffer()
        try? await door.refresh()
        return response()
    }

    func remove(deviceID: String) async -> NollieLinkIPCResponse {
        guard deviceID.utf8.count == 36, let id = UUID(uuidString: deviceID) else { return response(error: .invalidRequest) }
        do {
            guard try door.remove(id) else { return response(error: .notFound) }
        } catch { return response(error: .persistenceUnavailable) }
        try? await door.refresh()
        return response()
    }

    // MARK: Sharing at home

    /// The Mac app's side of sharing: list, a code for someone at home, a change to what they have,
    /// or the owner's answer to their ask. Removing someone is `remove(deviceID:)`.
    func family(_ request: NollieLinkIPCFamilyRequest) async -> NollieLinkIPCResponse {
        switch request.action {
        case .list:
            return response()
        case .invite:
            guard let person = request.person, let helpers = request.helpers else { return response(error: .invalidRequest) }
            let invite: LinkDoorDevices.Invite, shown: [String]
            switch await door.prepareShare(person: person, helpers: helpers) {
            case .failure(let failure): return familyFailure(failure)
            case .success(let checked): (invite, shown) = checked
            }
            let made = door.devices.makeOffer(invite: invite)
            do { try await door.start() } catch {
                door.devices.cancelOffer()
                return response(error: .unavailable)
            }
            guard let port = door.port else { return response(error: .unavailable) }
            scheduleExpiry(at: made.expiresAt)
            // At home only: someone a helper is shared with never reaches this Mac through Tailscale.
            let hosts = Array(Self.homeAddresses().prefix(7)) + (Self.localName().map { [$0] } ?? [])
            guard !hosts.isEmpty else { door.devices.cancelOffer(); return response(error: .unavailable) }
            var result = response()
            result.offer = NollieLinkIPCOffer(macName: door.configuration.name, pin: LinkDoorBase64URL.encode(door.identity.pin),
                                              port: Int(port), hosts: hosts, tag: door.devices.installTag,
                                              secret: LinkDoorBase64URL.encode(made.secret), expiresAt: made.expiresAt,
                                              owner: door.configuration.owner, helpers: shown)
            return result
        case .update:
            guard let id = request.member, request.helpers != nil || request.small != nil else { return response(error: .invalidRequest) }
            if let failure = await door.updateMember(id, helpers: request.helpers, small: request.small) { return familyFailure(failure) }
            return response()
        case .answer:
            guard let id = request.ask, let choice = request.choice, ["once", "deny"].contains(choice) else { return response(error: .invalidRequest) }
            if case .failure(let failure) = await door.answerAsk(id, choice: choice) { return familyFailure(failure) }
            return response()
        }
    }

    private func familyFailure(_ failure: LinkDoor.FamilyFailure) -> NollieLinkIPCResponse {
        var result = response(error: failure == .notFound ? .notFound : failure == .unsaved ? .persistenceUnavailable : .invalidRequest)
        result.familyIssue = failure.message
        return result
    }

    // MARK: Away from home

    /// Away from home as the Mac app shows it: the switch, what Nollie found of Tailscale, and a
    /// name typed in by the person. `on` and `host` change it when given ("" clears the name).
    func away(on: Bool?, host: String?) async -> NollieLinkIPCResponse {
        if let host, !host.isEmpty, !NollieTailnet.isTailnetHost(host) || !NollieTailnet.validLinkHost(host) {
            return response(error: .invalidRequest)
        }
        if on != nil || host != nil {
            do {
                let typed: String?? = host.map { $0.isEmpty ? nil : $0 }
                try door.devices.setAway(on ?? door.devices.away, host: typed)
            } catch { return response(error: .persistenceUnavailable) }
            if on == false { door.cutTailnet() }
            try? await door.refresh()
        }
        let status = await tailscaleStatus(fresh: true)
        // Behind an exit node, the relay looks again now, so the card never shows for a moment
        // before the relay has noticed a computer that just started.
        let relayState = status.exitNode ? await relay?.check() : await relay?.state
        var result = response()
        result.away = NollieLinkIPCAway(on: door.devices.away, tailscale: status.word, name: status.name,
                                        addresses: status.addresses, exitNode: status.exitNode,
                                        relay: relayState?.rawValue, host: door.devices.awayHost,
                                        hosts: await hosts(forCode: false))
        return result
    }

    /// What a linked phone is told after it connects.
    func phoneHosts() async -> (hosts: [String], tailscale: String) {
        let status = await tailscaleStatus(fresh: false)
        return (await hosts(forCode: false), status.word)
    }

    /// Tailscale's state, asked again at most every ten seconds unless the screen wants it now.
    private func tailscaleStatus(fresh: Bool) async -> TailscaleStatus {
        if !fresh, let tailscale, Date().timeIntervalSince(tailscale.at) < 10 { return tailscale.status }
        let status = await detector.detect()
        tailscale = (status, Date())
        return status
    }

    private func hosts(forCode: Bool) async -> [String] {
        let away = door.devices.away
        let status = away ? await tailscaleStatus(fresh: false) : .missing
        return NollieLinkHosts.make(lan: Self.homeAddresses(), localName: Self.localName(), tailscale: status,
                                    manual: door.devices.awayHost, away: away, forCode: forCode)
    }

    private func scheduleExpiry(at date: Date) {
        expiry?.cancel()
        let door = self.door
        expiry = Task {
            try? await Task.sleep(for: .seconds(max(1, date.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled else { return }
            try? await door.refresh()
        }
    }

    private func response(error: NollieLinkIPCError? = nil) -> NollieLinkIPCResponse {
        var result = NollieLinkIPCResponse(error: error)
        if case .claimed(_, let name) = door.devices.offerState() { result.claimedBy = name }
        result.stop = door.lastStop.map { NollieLinkIPCStop(generation: $0.generation, device: $0.device, at: $0.at) }
        result.devices = door.devices.devices.map {
            NollieLinkIPCDevice(id: $0.id, name: $0.name, linkedAt: $0.linkedAt, lastActive: $0.lastActive, person: $0.member?.person)
        }
        result.family = NollieLinkIPCFamily(
            members: door.devices.members.compactMap { device in
                device.member.map { NollieLinkIPCMember(id: device.id, person: $0.person, device: device.name, helpers: $0.helpers,
                                                        small: $0.small, linkedAt: device.linkedAt, lastActive: device.lastActive) }
            },
            asks: door.asks.all.map {
                NollieLinkIPCAsk(id: $0.id, person: $0.person, helper: $0.profile, chat: $0.chat, small: $0.small, at: $0.at,
                                 request: $0.request.count <= 8192 ? $0.request : Data("{}".utf8))
            })
        return result
    }

    // MARK: This Mac

    /// The first name on this Mac's account, shown to someone a helper is shared with ("Corey shares Scout").
    static func ownerName() -> String {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return LinkDoorDevices.cleanName(first) ?? ""
    }

    static func macName() -> String {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ""
        return LinkDoorDevices.cleanName(name) ?? "Mac"
    }

    /// Private IPv4 addresses on active interfaces, home networks only (no link-local, no Tailscale).
    static func homeAddresses() -> [String] {
        var seen = Set<String>()
        return NollieLinkInterfaces.addresses().filter { entry in
            entry.bytes.count == 4 && LinkDoorPolicy.allowsIPv4(entry.bytes, allowLoopback: false)
                && !(entry.bytes[0] == 169 && entry.bytes[1] == 254) && !NollieTailnet.isTailnetIPv4(entry.bytes)
                && seen.insert(entry.address).inserted
        }.map(\.address)
    }

    /// The Bonjour host name, `<LocalHostName>.local`.
    static func localName() -> String? {
        guard let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty,
              local.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { return nil }
        return local + ".local"
    }
}
#endif
