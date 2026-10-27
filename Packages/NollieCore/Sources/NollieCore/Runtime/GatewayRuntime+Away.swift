import Foundation

// Away from home through iCloud: the key swap that rides on Nollie Link. See Docs/specs/away-icloud.md.
extension GatewayRuntime {
    /// Where this phone keeps its away key for one linked Mac.
    public static func awayKeyAccount(_ connection: UUID) -> String {
        "away.phone.key." + connection.uuidString.lowercased()
    }

    /// The channel to the linked Mac, once keys were swapped. Nil before that, or for a gateway
    /// that isn't a linked Mac.
    public var awayChannel: AwayChannel? {
        guard connection.linkedMac?.sharedBy == nil, let macKey = connection.linkedMac?.awayKey,
              let raw = Keychain.get(account: Self.awayKeyAccount(connection.id)), let own = AwayKey(raw: raw) else { return nil }
        return try? AwayChannel(own: own, side: .phone, otherPublic: macKey)
    }

    /// Swaps away keys with the linked Mac over the pinned door: this phone's public key in, the
    /// Mac's out. Only public keys travel; the door already proved who both ends are. True when the
    /// phone holds the Mac's key afterwards.
    @discardableResult
    public func swapAwayKeys() async -> Bool {
        // A phone that joined as someone a helper was shared with never swaps: the door refuses it too.
        guard let linked = connection.linkedMac, linked.sharedBy == nil, !linkDemo else { return false }
        let id = connection.id
        guard let own = try? AwayKey.loadOrCreate(account: Self.awayKeyAccount(id)),
              let body = try? JSONSerialization.data(withJSONObject: ["key": AwayBase64URL.encode(own.publicKey)]),
              let (data, response) = try? await api.raw("POST", NollieLinkClient.sealPath, body: (body, "application/json"),
                                                        authenticated: true, timeout: 8),
              response.statusCode == 200, data.count <= 1024, connection.id == id,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["key"],
              let text = object["key"] as? String, let macKey = AwayBase64URL.decode(text), AwayKey.validPublic(macKey),
              var link = connection.linkedMac else { return false }
        guard link.awayKey != macKey else { return true }
        link.awayKey = macKey
        connection.linkedMac = link
        if var saved = store.connection(id: id), saved.linkedMac?.pin == link.pin {
            saved.linkedMac?.awayKey = macKey
            store.updateMetadata(saved)
        }
        return true
    }
}
