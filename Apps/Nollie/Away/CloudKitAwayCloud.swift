import CloudKit
import Foundation
import NollieCore

/// The away mailbox in the person's own private iCloud database: one zone, two record types and a
/// subscription per device. The box sits in `encryptedValues`, and is sealed between the two
/// paired devices before that. Nothing here reads the box. See Docs/specs/away-icloud.md.
@MainActor
final class CloudKitAwayCloud: AwayCloud {
    nonisolated static let zoneName = "NollieAwayV1"
    nonisolated static let noteType = "NollieAwayNoteV1"
    nonisolated static let presenceType = "NollieAwayPresenceV1"
    nonisolated static let macSubscription = "nollie-away-mac-v1"
    nonisolated static let phoneSubscription = "nollie-away-phone-v1"
    nonisolated static let phoneAlertSubscription = "nollie-away-phone-alert-v1"
    nonisolated static let subscriptions = [macSubscription, phoneSubscription, phoneAlertSubscription]
    /// The words on a visible notification. Nothing from the record is ever in it.
    nonisolated static let alertWords = "Nollie has something for you."

    nonisolated static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName) }

    private let containerID: String
    private lazy var container = CKContainer(identifier: containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
    private var zoneReady = false

    init(containerID: String = CloudKitAlertStore.containerIdentifier) { self.containerID = containerID }

    enum Failure: Error, Equatable { case accountUnavailable }

    /// True when iCloud is signed in and CloudKit can be used for this app.
    func accountAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        guard try await container.accountStatus() == .available else { throw Failure.accountUnavailable }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
        zoneReady = true
    }

    // MARK: AwayCloud

    func post(_ record: AwayRecord) async throws {
        try await ensureZone()
        let saved = CKRecord(recordType: Self.noteType, recordID: CKRecord.ID(recordName: record.header.id, zoneID: Self.zoneID))
        saved["v"] = 1
        saved["fromTag"] = record.header.from
        saved["toTag"] = record.header.to
        saved["expiresAt"] = record.header.expiresAt
        saved["alert"] = record.header.alert ? 1 : 0
        saved.encryptedValues["box"] = record.box
        do { _ = try await database.save(saved) }
        catch let error as CKError where error.code == .zoneNotFound {
            // The zone went (Remove Nollie on another device, or iCloud data reset): make it again once.
            zoneReady = false
            try await ensureZone()
            _ = try await database.save(saved)
        }
    }

    func fetch(to tag: String) async throws -> [AwayRecord] {
        try await ensureZone()
        let query = CKQuery(recordType: Self.noteType, predicate: NSPredicate(format: "toTag == %@", tag))
        let page = try await database.records(matching: query, inZoneWith: Self.zoneID, desiredKeys: nil, resultsLimit: 100)
        var found: [(AwayRecord, Date)] = []
        var unreadable: [CKRecord.ID] = []
        for (id, result) in page.matchResults {
            guard let record = try? result.get() else { continue }
            if let read = Self.decode(record) { found.append((read, record.creationDate ?? .distantPast)) }
            else { unreadable.append(id) }
        }
        // A record this build can't read at all is in our zone under our address: it goes.
        if !unreadable.isEmpty { _ = try? await database.modifyRecords(saving: [], deleting: unreadable) }
        return found.sorted { $0.1 < $1.1 }.map(\.0)
    }

    nonisolated static func decode(_ record: CKRecord) -> AwayRecord? {
        let id = record.recordID.recordName
        guard record.recordType == noteType, AwayHeader.isValidID(id), record["v"] as? Int == 1,
              let from = record["fromTag"] as? String, let to = record["toTag"] as? String,
              let expiresAt = record["expiresAt"] as? Date, let alert = record["alert"] as? Int, alert == 0 || alert == 1,
              let box = record.encryptedValues["box"] as? Data, box.count <= AwayChannel.maximumBox else { return nil }
        let header = AwayHeader(id: id, from: from, to: to, expiresAt: expiresAt, alert: alert == 1)
        guard header.isWellFormed else { return nil }
        return AwayRecord(header: header, box: box)
    }

    func delete(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let names = ids.filter(AwayHeader.isValidID).map { CKRecord.ID(recordName: $0, zoneID: Self.zoneID) }
        _ = try await database.modifyRecords(saving: [], deleting: names)
    }

    func deleteExpired(from tag: String, before: Date) async throws {
        try await ensureZone()
        let query = CKQuery(recordType: Self.noteType,
                            predicate: NSPredicate(format: "fromTag == %@ AND expiresAt < %@", tag, before as NSDate))
        let page = try await database.records(matching: query, inZoneWith: Self.zoneID, desiredKeys: ["expiresAt"], resultsLimit: 200)
        let ids = page.matchResults.map(\.0)
        if !ids.isEmpty { _ = try await database.modifyRecords(saving: [], deleting: ids) }
    }

    func setPresence(tag: String, at: Date) async throws {
        try await ensureZone()
        let record = CKRecord(recordType: Self.presenceType, recordID: CKRecord.ID(recordName: "ap1_" + tag, zoneID: Self.zoneID))
        record["seenAt"] = at
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }

    func presence(tag: String) async throws -> Date? {
        try await ensureZone()
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: "ap1_" + tag, zoneID: Self.zoneID))
            return record.recordType == Self.presenceType ? record["seenAt"] as? Date : nil
        } catch let error as CKError where error.code == .unknownItem { return nil }
    }

    // MARK: Subscriptions

    /// The Mac hears every record addressed to it, silently; the phone hears its own, with a
    /// visible notification only for the ones that ask for it.
    func subscribe(tag: String, side: AwaySide) async throws {
        try await ensureZone()
        let made: [CKSubscription] = switch side {
        case .mac: [Self.subscription(id: Self.macSubscription, predicate: NSPredicate(format: "toTag == %@", tag), visible: false)]
        case .phone: [
            Self.subscription(id: Self.phoneSubscription, predicate: NSPredicate(format: "toTag == %@ AND alert == 0", tag), visible: false),
            Self.subscription(id: Self.phoneAlertSubscription, predicate: NSPredicate(format: "toTag == %@ AND alert == 1", tag), visible: true),
        ]
        }
        _ = try await database.modifySubscriptions(saving: made, deleting: [])
    }

    nonisolated static func subscription(id: String, predicate: NSPredicate, visible: Bool) -> CKQuerySubscription {
        let subscription = CKQuerySubscription(recordType: noteType, predicate: predicate, subscriptionID: id, options: [.firesOnRecordCreation])
        subscription.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        if visible {
            info.title = "Nollie"
            info.alertBody = alertWords
            info.soundName = "default"
        } else {
            info.shouldSendContentAvailable = true
        }
        // No fields from the record ride along: the push only says to look.
        info.desiredKeys = []
        subscription.notificationInfo = info
        return subscription
    }

    func unsubscribe(side: AwaySide) async {
        let ids = side == .mac ? [Self.macSubscription] : [Self.phoneSubscription, Self.phoneAlertSubscription]
        _ = try? await database.modifySubscriptions(saving: [], deleting: ids)
    }

    /// Turning it off, or Remove Nollie: this device's subscriptions, and its own records.
    func forget(tag: String, side: AwaySide) async {
        await unsubscribe(side: side)
        try? await deleteExpired(from: tag, before: .distantFuture)
    }

    /// Remove Nollie, when the person ticks it: the whole away zone, with every record in it.
    func deleteEverything() async throws {
        for side in [AwaySide.mac, .phone] { await unsubscribe(side: side) }
        do { _ = try await database.modifyRecordZones(saving: [], deleting: [Self.zoneID]) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {}
        zoneReady = false
    }

    /// A push from one of the away subscriptions.
    nonisolated static func isAwayPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              notification.containerIdentifier == CloudKitAlertStore.containerIdentifier,
              let id = notification.subscriptionID else { return false }
        return subscriptions.contains(id)
    }
}
