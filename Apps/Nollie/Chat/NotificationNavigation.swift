import Foundation
import SwiftUI
import NollieCore

/// A message address is independent of its text and of a row's temporary view identity.
struct NotificationMessageFocus: Hashable, Sendable {
    let token: UUID
    let rowID: Int?
    let itemID: String?

    func matches(_ item: TranscriptItem) -> Bool {
        if let rowID { return item.rowID == rowID }
        return itemID.map { item.id == $0 } ?? false
    }

    func anchor(in rows: [TranscriptRowModel]) -> String? {
        rows.first { matches($0.item) || $0.run.contains(where: matches) }?.id
    }
}

enum NotificationNavigation {
    static func connection(for route: PendingRoute, among connections: [GatewayConnection]) -> GatewayConnection? {
        if let identity = route.gatewayIdentity {
            guard GatewayIdentity.isValid(identity) else { return nil }
            let matches = connections.filter { $0.gatewayIdentity == identity }
            if let exact = matches.first(where: { $0.id == route.connectionID }) { return exact }
            return matches.count == 1 ? matches.first : nil
        }
        if let fingerprint = route.gatewayFingerprint {
            let matches = connections.filter { CloudAlertTarget.fingerprint(for: $0.gateway) == fingerprint }
            if let exact = matches.first(where: { $0.id == route.connectionID }) { return exact }
            return matches.count == 1 ? matches.first : nil
        }
        if let id = route.connectionID, let exact = connections.first(where: { $0.id == id }) {
            guard route.gateway.map({ (try? GatewayURL.normalize($0)) == exact.gateway }) ?? true else { return nil }
            return exact
        }
        if let address = route.gateway, let gateway = try? GatewayURL.normalize(address) {
            let matches = connections.filter { $0.gateway == gateway }
            return matches.count == 1 ? matches.first : nil
        }
        // Older pushes omitted connection metadata. Only one saved gateway is unambiguous.
        guard route.connectionID == nil, route.gateway == nil, connections.count == 1 else { return nil }
        return connections.first
    }

    static func sessionMatches(_ metadata: JSONValue, route: PendingRoute) -> Bool {
        metadata["id"]?.stringValue == route.storedSessionID
            && metadata["profile"]?.stringValue == (route.profile ?? "default")
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func matches(_ route: PendingRoute, connectionID: UUID, profile: String, sessionID: String,
                        requestedSessionID: String? = nil) -> Bool {
        (route.connectionID == nil || route.connectionID == connectionID)
            && (route.profile == nil || route.profile == profile)
            && (route.storedSessionID == sessionID || route.storedSessionID == requestedSessionID)
    }
}

extension View {
    func notificationNavigation(_ model: AppModel) -> some View {
        onChange(of: model.lock.isLocked, initial: true) { _, _ in model.notificationLockChanged() }
            .alert("Couldn’t open notification", isPresented: Binding(
                get: { model.notificationRouteError != nil },
                set: { if !$0 { model.notificationRouteError = nil } }
            )) { Button("OK", role: .cancel) { model.notificationRouteError = nil } }
            message: { Text(model.notificationRouteError ?? "") }
            .alert("Couldn’t open your chat", isPresented: Binding(
                get: { model.askNollieError != nil },
                set: { if !$0 { model.askNollieError = nil } }
            )) { Button("OK", role: .cancel) { model.askNollieError = nil } }
            message: { Text(model.askNollieError ?? "") }
    }
}
