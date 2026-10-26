import CoreGraphics
import ImageIO
import Intents
import UniformTypeIdentifiers
import UserNotifications
import NollieCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Fills in a notification before it shows: opens the encrypted companion payload, or fetches a
/// private iCloud preview, and presents the result as a message from the bot. Details appear only
/// when this device allows them; the system keeps a generic alert as the fallback if time runs out.
final class NotificationService: UNNotificationServiceExtension {
    private var gate: NotificationDeliveryGate?
    private var isCloudPreview = false

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        isCloudPreview = false
        Keychain.accessGroup = Keychain.sharedGroupFromBundle()
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        let plain = (content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        Self.makeGeneric(plain)
        let gate = NotificationDeliveryGate(fallback: plain, handler: contentHandler)
        self.gate = gate

        if let eventID = CloudAlertNotificationResolver.eventID(in: content.userInfo) {
            isCloudPreview = true
            resolveCloudPreview(eventID, into: content, gate: gate)
        } else if let sealed = request.content.userInfo["enc"] as? String {
            openSealed(sealed, into: content, gate: gate)
        } else {
            Self.note("plain notification (no enc)")
            Self.present(content, profile: Self.routing("profile", in: request.content),
                         connection: UUID(uuidString: Self.routing("connection_id", in: request.content)), gate: gate)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if gate?.finish() == true, isCloudPreview { CloudAlertPreviewDiagnostic.record(.timedOut) }
    }

    /// One string from the "hermes" block of a notification's user info, or empty.
    private static func routing(_ field: String, in content: UNNotificationContent) -> String {
        guard let block = content.userInfo["hermes"] as? [String: Any] else { return "" }
        return block[field] as? String ?? ""
    }

    private static func makeGeneric(_ content: UNMutableNotificationContent) {
        content.title = CloudAlertPreview.genericTitle
        content.subtitle = ""
        content.body = CloudAlertPreview.genericBody
        content.attachments = []
    }

    // MARK: Private iCloud previews

    private func resolveCloudPreview(_ eventID: String, into content: UNMutableNotificationContent, gate: NotificationDeliveryGate) {
        guard let policy = NotificationPreviewPolicy.load() else {
            CloudAlertPreviewDiagnostic.record(.policyUnavailable)
            gate.finish()
            return
        }
        if let reason = CloudAlertPreviewResolution.policyFailure(policy) {
            CloudAlertPreviewDiagnostic.record(reason)
            gate.finish()
            return
        }
        CloudAlertPreviewDiagnostic.record(.checking)
        nonisolated(unsafe) let target = content
        gate.track(Task { @MainActor in
            let result = await CloudAlertNotificationResolver().resolve(eventID)
            guard !gate.isFinished else { return }
            CloudAlertPreviewDiagnostic.record(result.outcome)
            guard let event = result.event, let preview = event.preview, let destination = event.target else {
                gate.finish()
                return
            }
            // The person may have switched previews off while this was fetched.
            guard NotificationPreviewPolicy.load()?.allowsPreview(matching: policy) == true else {
                CloudAlertPreviewDiagnostic.record(.privacyChanged)
                gate.finish()
                return
            }
            target.title = preview.title
            target.subtitle = ""
            target.body = preview.body
            if event.kind == .computerStarted {
                // "Scout started using your Mac" comes with Stop on the iPhone. The Mac it is about
                // gets it quietly, since the person there can see the task.
                target.categoryIdentifier = "NOLLIE_COMPUTER"
                #if os(macOS)
                target.interruptionLevel = .passive
                #endif
            } else {
                target.categoryIdentifier = "HERMES_CLOUD_REPLY"
            }
            target.threadIdentifier = CloudAlertEvent.digest([destination.gatewayFingerprint, destination.profile, destination.sessionID].joined(separator: "/"))
            Self.present(target, profile: destination.profile, connection: destination.connectionID, gate: gate, policy: policy)
        })
    }

    // MARK: Encrypted companion payloads

    private func openSealed(_ sealed: String, into content: UNMutableNotificationContent, gate: NotificationDeliveryGate) {
        guard let credentials = Keychain.getCodable(PushRelay.Credentials.self, account: PushRelay.credentialsAccount) else {
            Self.note("no relay credentials readable")
            gate.finish()
            return
        }
        let fields: [String: JSONValue]
        do {
            fields = try PushRelay.decrypt(sealed, keyBase64: credentials.payloadKey)
        } catch {
            Self.note("decrypt failed")
            gate.finish()
            return
        }
        Self.note("decrypted OK")
        if let title = fields["title"]?.stringValue { content.title = title }
        if let subtitle = fields["subtitle"]?.stringValue { content.subtitle = subtitle }
        if let body = fields["body"]?.stringValue { content.body = body }
        if let category = fields["category"]?.stringValue { content.categoryIdentifier = category }
        if let thread = fields["thread_id"]?.stringValue, !thread.isEmpty { content.threadIdentifier = thread }
        if fields["interruption"]?.stringValue == "time-sensitive" { content.interruptionLevel = .timeSensitive }
        var profile = ""
        var connection: UUID?
        if let hermes = fields["hermes"]?.objectValue {
            var info = content.userInfo
            info["hermes"] = hermes.mapValues { $0.foundationValue }
            content.userInfo = info
            profile = hermes["profile"]?.stringValue ?? ""
            connection = hermes["connection_id"]?.stringValue.flatMap { UUID(uuidString: $0) }
        }
        gate.updateRouting(content.userInfo)
        Self.present(content, profile: profile, connection: connection, gate: gate)
    }

    // MARK: Presenting as a message

    private static let botCategories: Set<String> = ["HERMES_TURN", "HERMES_ERROR", "HERMES_APPROVAL", "HERMES_CLARIFY",
                                                      "HERMES_CLOUD_REPLY", "NOLLIE_COMPUTER"]

    /// Anything from a bot is shown as a message from it; other notifications (the test) keep the
    /// plain look. Nothing goes out unless this device's preview policy still allows it, and the
    /// Private list is read again each time, since the app may have changed it since this
    /// extension last ran. A push that names no gateway is held back if any gateway has the bot private.
    private static func present(_ content: UNMutableNotificationContent, profile: String, connection: UUID?,
                                gate: NotificationDeliveryGate, policy: NotificationPreviewPolicy? = nil) {
        let previewsAllowed: () -> Bool = {
            let allowed = NotificationPreviewPolicy.load()?.allowsPreview(matching: policy) == true
            if !allowed && policy != nil { CloudAlertPreviewDiagnostic.record(.privacyChanged) }
            return allowed
        }
        if gate.isFinished || !previewsAllowed() || PrivateBots.isPrivate(profile, connection: connection, fresh: true) {
            gate.finish()
            return
        }
        let trimmed = CloudAlertPreview(title: content.title.isEmpty ? "Nollie" : content.title, body: content.body)
        (content.title, content.body) = (trimmed.title, trimmed.body)
        content.subtitle = CloudAlertPreview(title: content.subtitle, body: "").title
        if !botCategories.contains(content.categoryIdentifier) || content.title.isEmpty {
            gate.finish(content)
            return
        }
        let kind = routing("kind", in: content)
        // Building the sender happens on the main actor. Content and the system's completion closure are
        // both non-Sendable, and nothing else touches them past this point.
        nonisolated(unsafe) let handedOver = content
        Task { @MainActor in
            guard !gate.isFinished, previewsAllowed() else { gate.finish(); return }
            let styled = asMessage(handedOver, profile: profile, kind: kind)
            // The person may have turned previews off while the picture was drawn.
            guard previewsAllowed() else { gate.finish(); return }
            if gate.finish(styled), policy != nil { CloudAlertPreviewDiagnostic.record(.detailsSupplied) }
        }
    }

    /// The bot's name and avatar for a notification: Nollie's own look for a test, else the person's saved one.
    @MainActor
    private static func senderLook(for content: UNMutableNotificationContent, profile: String, kind: String)
        -> (name: String, handle: String, picture: Data?) {
        let isTest = kind == "test"
        // A test comes from no particular bot: Nollie's own look, and no Reply action.
        let profile = isTest ? "nollie" : profile
        var looks = BotLooks.load()
        if isTest {
            looks.avatars[profile] = CharacterChoice.look(.main).raw
            content.categoryIdentifier = "HERMES_TEST"
        }
        // Title is either the bot's name or "<bot> · approval needed". Everything before the dot is the sender.
        let name = content.title.split(separator: " · ", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? content.title
        let key = looks.key(profile: profile, label: name)
        let choice = looks.choice(key: key, profile: profile)
        note("look for profile '\(profile)' / bot '\(name)' is \(key ?? "none"), \(choice.raw) (\(looks.avatars.count) bots known)")
        let photo = key.flatMap { looks.photos[$0] }
        return (name, profile.isEmpty ? name : profile, AvatarRender.image(choice, photo: photo, profile: profile))
    }

    @MainActor
    private static func asMessage(_ content: UNMutableNotificationContent, profile: String, kind: String) -> UNNotificationContent {
        let look = senderLook(for: content, profile: profile, kind: kind)
        let thread = content.threadIdentifier
        let intent = messageIntent(from: sender(named: look.name, handle: look.handle, picture: look.picture),
                                   saying: content.body, in: thread.isEmpty ? look.handle : thread)
        #if os(iOS)
        if let picture = look.picture { intent.setImage(INImage(imageData: picture), forParameterNamed: \.sender) }
        #endif
        donate(intent)
        do {
            let styled = try content.updating(from: intent)
            note("shown as a message from \(look.name)")
            return styled
        } catch {
            note("message style failed")
            return content
        }
    }

    /// Tells the system about the message, so the sender can turn up in suggestions.
    private static func donate(_ intent: INSendMessageIntent) {
        let record = INInteraction(intent: intent, response: nil)
        record.direction = .incoming
        record.donate(completion: nil)
    }

    private static func sender(named name: String, handle: String, picture: Data?) -> INPerson {
        let image = picture.map { INImage(imageData: $0) }
        return INPerson(personHandle: INPersonHandle(value: handle, type: .unknown), nameComponents: nil, displayName: name,
                        image: image, contactIdentifier: nil, customIdentifier: handle, isMe: false, suggestionType: .none)
    }

    private static func messageIntent(from sender: INPerson, saying text: String, in conversation: String) -> INSendMessageIntent {
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: text,
                                         speakableGroupName: nil, conversationIdentifier: conversation, serviceName: nil,
                                         sender: sender, attachments: nil)
        return intent
    }

    /// The notifications page reads this line back to show what happened most recently.
    static func note(_ what: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + " " + what
        try? Keychain.set(Data(line.utf8), account: "push.nse.last")
    }
}

/// A bot's picture as PNG for the notification's sender: its photo cropped round, or its look's still.
enum AvatarRender {
    private static let side = 256

    static func image(_ choice: CharacterChoice, photo: Data?, profile: String) -> Data? {
        if choice == .photo, let photo, let round = rounded(photo) { return round }
        let asset = CharacterDrawing.avatarName(choice.look(forProfile: profile))
        #if canImport(UIKit)
        return UIImage(named: asset)?.pngData()
        #else
        return NSImage(named: asset)?.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(encode)
        #endif
    }

    /// Fills a circle with the photo, scaled to cover it and centred, and returns it as PNG.
    private static func rounded(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let photo = CGImageSourceCreateImageAtIndex(source, 0, nil), photo.width > 0, photo.height > 0 else { return nil }
        let edge = CGFloat(side)
        let canvas = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let canvas else { return nil }
        canvas.addEllipse(in: CGRect(origin: .zero, size: CGSize(width: edge, height: edge)))
        canvas.clip()
        let zoom = edge / CGFloat(min(photo.width, photo.height))
        let (w, h) = (CGFloat(photo.width) * zoom, CGFloat(photo.height) * zoom)
        canvas.draw(photo, in: CGRect(x: (edge - w) / 2, y: (edge - h) / 2, width: w, height: h))
        return canvas.makeImage().flatMap(encode)
    }

    private static func encode(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(writer, image, nil)
        return CGImageDestinationFinalize(writer) ? output as Data : nil
    }
}
