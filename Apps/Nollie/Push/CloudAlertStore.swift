import CloudKit
import Foundation

@MainActor
protocol CloudAlertStore {
    func accountFingerprint() async throws -> String
    func enabled() async throws -> Bool
    func setEnabled(_ enabled: Bool) async throws
    func installSubscription() async throws
    func subscriptionState() async throws -> CloudAlertSubscriptionState
    func removeSubscription() async throws
    func create(_ event: CloudAlertEvent) async throws
    func event(_ id: String) async throws -> CloudAlertEvent?
    func latestUnexpiredTest(at date: Date) async throws -> CloudAlertTestLookup
    func receipt(_ id: String) async throws -> CloudAlertTestStatus?
    func acknowledge(_ event: CloudAlertEvent, opened: Bool, at: Date) async throws
    func cleanExpired(source: String, before: Date) async throws
}

/// This store touches only the three Nollie alert record types in the private database.
@MainActor
final class CloudKitAlertStore: CloudAlertStore {
    nonisolated static let containerIdentifier = "iCloud.com.coreykozarski.nollie"
    nonisolated static let subscriptionID = "nollie-alert-events-v1"
    static let preferencesType = "NollieAlertPreferencesV1"
    static let preferencesID = "nollie-alert-preferences-v1"
    static let receiptType = "NollieAlertReceiptV1"
    private let containerID: String
    private lazy var container = CKContainer(identifier: containerID)
    private var database: CKDatabase { container.privateCloudDatabase }

    init(containerID: String = CloudKitAlertStore.containerIdentifier) { self.containerID = containerID }

    func accountFingerprint() async throws -> String {
        guard try await container.accountStatus() == .available else { throw CloudAlertFailure.unavailable }
        return CloudAlertEvent.digest(try await container.userRecordID().recordName)
    }

    func enabled() async throws -> Bool {
        guard let record = try await fetch(Self.preferencesID) else { return false }
        guard record.recordType == Self.preferencesType, record["version"] as? Int == 1 else {
            throw CloudAlertFailure.invalidRecord
        }
        return record["enabled"] as? Int == 1
    }

    func setEnabled(_ enabled: Bool) async throws {
        let record = try await fetch(Self.preferencesID) ?? CKRecord(recordType: Self.preferencesType,
            recordID: CKRecord.ID(recordName: Self.preferencesID))
        guard record.recordType == Self.preferencesType else { throw CloudAlertFailure.invalidRecord }
        record["version"] = 1
        record["enabled"] = enabled ? 1 : 0
        _ = try await database.save(record)
    }

    func installSubscription() async throws {
        let saved = try await database.save(Self.makeSubscription())
        guard Self.subscriptionState(saved) == .valid else { throw CloudAlertFailure.subscriptionInvalid }
    }

    func subscriptionState() async throws -> CloudAlertSubscriptionState {
        do { return Self.subscriptionState(try await database.subscription(for: Self.subscriptionID)) }
        catch let error as CKError where error.code == .unknownItem { return .missing }
    }

    static func subscriptionState(_ subscription: CKSubscription?) -> CloudAlertSubscriptionState {
        guard let subscription else { return .missing }
        let expected = makeSubscription()
        guard let query = subscription as? CKQuerySubscription,
              query.subscriptionID == subscriptionID, query.recordType == CloudAlertEvent.recordType,
              query.zoneID == expected.zoneID, query.querySubscriptionOptions == expected.querySubscriptionOptions,
              query.predicate.isEqual(expected.predicate),
              let info = query.notificationInfo, let expectedInfo = expected.notificationInfo,
              info.title == expectedInfo.title, info.alertBody == expectedInfo.alertBody,
              info.soundName == expectedInfo.soundName, !info.shouldSendContentAvailable,
              !info.shouldBadge, info.desiredKeys?.isEmpty != false else { return .invalid }
        return info.shouldSendMutableContent ? .valid : .legacy
    }

    static func makeSubscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(recordType: CloudAlertEvent.recordType,
            predicate: NSPredicate(format: "version == 1"), subscriptionID: Self.subscriptionID,
            options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        // Kept in iCloud and compared on every device (`subscriptionState`), so it stays in English.
        // The notification extension puts the shown words in place.
        info.title = "Nollie"
        info.alertBody = "There’s an update waiting for you in Nollie."
        info.soundName = "default"
        info.shouldSendMutableContent = true
        // The record ID is already part of a query notification. No message fields are included.
        subscription.notificationInfo = info
        return subscription
    }

    func removeSubscription() async throws {
        do { _ = try await database.deleteSubscription(withID: Self.subscriptionID) }
        catch let error as CKError where error.code == .unknownItem { }
    }

    func create(_ event: CloudAlertEvent) async throws {
        guard CloudAlertEvent.isValidID(event.id), event.target?.isValid != false,
              event.preview?.isValid != false else { throw CloudAlertFailure.invalidRecord }
        let record = CKRecord(recordType: CloudAlertEvent.recordType, recordID: CKRecord.ID(recordName: event.id))
        record["version"] = 1; record["source"] = event.source; record["kind"] = event.kind.rawValue
        record["createdAt"] = event.createdAt; record["expiresAt"] = event.expiresAt
        if let target = event.target {
            record["target"] = String(decoding: try JSONEncoder().encode(target), as: UTF8.self)
        }
        if let preview = event.preview {
            record["previewTitle"] = preview.title
            record["previewBody"] = preview.body
        }
        do { _ = try await database.save(record) }
        catch let error as CKError where error.code == .serverRecordChanged {
            // A deterministic ID is immutable. Retrying a successful write never creates a second alert.
            guard let existing = try await self.event(event.id), existing.source == event.source,
                  existing.kind == event.kind else { throw CloudAlertFailure.invalidRecord }
        }
    }

    func event(_ id: String) async throws -> CloudAlertEvent? {
        guard CloudAlertEvent.isValidID(id) else { throw CloudAlertFailure.invalidRecord }
        guard let record = try await fetch(id) else { return nil }
        return try Self.decodeEvent(record)
    }

    func latestUnexpiredTest(at date: Date) async throws -> CloudAlertTestLookup {
        // Use the existing version index. No new schema, sort index or subscription is required.
        let query = CKQuery(recordType: CloudAlertEvent.recordType, predicate: NSPredicate(format: "version == 1"))
        let page = try await database.records(matching: query,
            desiredKeys: ["version", "source", "kind", "createdAt", "expiresAt"], resultsLimit: 100)
        // Only test events matter here: a record this build can't read (a kind a newer build
        // added, such as computerStarted) is left out rather than failing the whole check.
        let events = page.matchResults.compactMap { try? Self.decodeEvent($0.1.get()) }
        return CloudAlertTestLookup.select(from: events, at: date, isLimited: page.queryCursor != nil)
    }

    static func decodeEvent(_ record: CKRecord) throws -> CloudAlertEvent {
        let id = record.recordID.recordName
        guard CloudAlertEvent.isValidID(id) else { throw CloudAlertFailure.invalidRecord }
        guard record.recordType == CloudAlertEvent.recordType, record["version"] as? Int == 1,
              let source = record["source"] as? String, let rawKind = record["kind"] as? String,
              let kind = CloudAlertKind(rawValue: rawKind), let createdAt = record["createdAt"] as? Date,
              let expiresAt = record["expiresAt"] as? Date else { throw CloudAlertFailure.invalidRecord }
        guard source.count == 64, source.allSatisfy({ "0123456789abcdef".contains($0) }),
              expiresAt > createdAt, expiresAt.timeIntervalSince(createdAt) <= CloudAlertEvent.retention else {
            throw CloudAlertFailure.invalidRecord
        }
        var target: CloudAlertTarget?
        if let raw = record["target"] as? String {
            guard raw.utf8.count <= 2048,
                  let decoded = try? JSONDecoder().decode(CloudAlertTarget.self, from: Data(raw.utf8)),
                  decoded.isValid else { throw CloudAlertFailure.invalidRecord }
            target = decoded
        }
        var preview: CloudAlertPreview?
        if let title = record["previewTitle"] as? String, let body = record["previewBody"] as? String {
            guard title.utf8.count <= 512, body.utf8.count <= 2048 else { throw CloudAlertFailure.invalidRecord }
            let decoded = CloudAlertPreview(title: title, body: body)
            guard decoded.isValid, decoded.title == title, decoded.body == body else { throw CloudAlertFailure.invalidRecord }
            preview = decoded
        }
        return CloudAlertEvent(id: id, source: source, kind: kind, createdAt: createdAt, expiresAt: expiresAt,
                               target: target, preview: preview)
    }

    func receipt(_ id: String) async throws -> CloudAlertTestStatus? {
        guard CloudAlertEvent.isValidID(id) else { throw CloudAlertFailure.invalidRecord }
        guard let record = try await fetch("ack_" + id) else { return nil }
        guard record.recordType == Self.receiptType, record["version"] as? Int == 1 else {
            throw CloudAlertFailure.invalidRecord
        }
        return CloudAlertTestStatus(stored: true, receivedAt: record["receivedAt"] as? Date,
                                   openedAt: record["openedAt"] as? Date)
    }

    func acknowledge(_ event: CloudAlertEvent, opened: Bool, at: Date) async throws {
        let id = "ack_" + event.id
        let record = CKRecord(recordType: Self.receiptType, recordID: CKRecord.ID(recordName: id))
        record["version"] = 1; record["source"] = event.source; record["expiresAt"] = event.expiresAt
        record["receivedAt"] = at
        if opened { record["openedAt"] = at }
        // Concurrent acknowledgments may refresh their dates, but never erase an opened receipt.
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
        _ = try result.saveResults[record.recordID]?.get()
    }

    func cleanExpired(source: String, before: Date) async throws {
        for type in [CloudAlertEvent.recordType, Self.receiptType] {
            let query = CKQuery(recordType: type, predicate: NSPredicate(format: "source == %@ AND expiresAt < %@", source, before as NSDate))
            let results = try await database.records(matching: query, desiredKeys: ["expiresAt", "source"], resultsLimit: 25)
            let ids = results.matchResults.compactMap { _, result -> CKRecord.ID? in
                guard let record = try? result.get(), record["source"] as? String == source,
                      let expires = record["expiresAt"] as? Date, expires < before else { return nil }
                return record.recordID
            }
            if !ids.isEmpty {
                let deleted = try await database.modifyRecords(saving: [], deleting: ids)
                for result in deleted.deleteResults.values { _ = try result.get() }
            }
        }
    }

    /// Remove Nollie, when the person ticks it: the alert subscription, the preference record, and
    /// every alert and receipt record in Nollie's private iCloud database. Only Nollie's own types.
    func deleteEverything() async throws {
        try await removeSubscription()
        do { _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: Self.preferencesID)) }
        catch let error as CKError where error.code == .unknownItem {}
        for type in [CloudAlertEvent.recordType, Self.receiptType] {
            for _ in 0..<50 {
                let query = CKQuery(recordType: type, predicate: NSPredicate(format: "expiresAt < %@", Date.distantFuture as NSDate))
                let page = try await database.records(matching: query, desiredKeys: ["expiresAt"], resultsLimit: 200)
                let ids = page.matchResults.compactMap { id, result -> CKRecord.ID? in
                    guard let record = try? result.get(), record.recordType == type else { return nil }
                    return id
                }
                if ids.isEmpty { break }
                let deleted = try await database.modifyRecords(saving: [], deleting: ids)
                for result in deleted.deleteResults.values { _ = try result.get() }
            }
        }
    }

    private func fetch(_ id: String) async throws -> CKRecord? {
        do { return try await database.record(for: CKRecord.ID(recordName: id)) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }
}
