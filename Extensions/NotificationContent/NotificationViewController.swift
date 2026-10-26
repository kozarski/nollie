import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI
import NollieCore

/// The expanded notification for a reply, styled like a message: the bot's picture and name,
/// which chat it belongs to, and the text inside a bubble. The Reply box underneath is supplied
/// by the system through the category's text action.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var hosting: UIHostingController<ReplyCard>?

    func didReceive(_ notification: UNNotification) {
        let card = ReplyCard(model: .init(notification))
        if let hosting {
            hosting.rootView = card
        } else {
            hosting = embed(card)
        }
        // Before the first layout there is no width yet; the next layout pass sizes it properly.
        resize(to: view.bounds.width > 0 ? view.bounds.width : (view.window?.bounds.width ?? 320) - 16)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.bounds.width > 0 { resize(to: view.bounds.width) }
    }

    /// Fits the content height to `width`, within what the system leaves above the reply field.
    private func resize(to width: CGFloat) {
        let natural = hosting?.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height ?? 120
        // A share of the window the notification is shown in, whichever display that is.
        let ceiling = max(200, (view.window?.bounds.height ?? 0) * 0.29)
        let height = (96...ceiling).clamp(natural)
        if abs(height - preferredContentSize.height) > 1 || preferredContentSize.width != width {
            preferredContentSize = CGSize(width: width, height: height)
        }
    }

    private func embed(_ card: ReplyCard) -> UIHostingController<ReplyCard> {
        let child = UIHostingController(rootView: card)
        child.view.backgroundColor = .clear
        // Pinned with constraints: the bounds are still zero here, and an autoresizing mask would keep them so.
        child.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(child)
        view.addSubview(child.view)
        let host = child.view!
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        child.didMove(toParent: self)
        return child
    }
}

private extension ClosedRange where Bound == CGFloat {
    func clamp(_ value: CGFloat) -> CGFloat { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

extension ReplyCard.Model {
    init(_ notification: UNNotification) {
        let content = notification.request.content
        let info = content.userInfo["hermes"] as? [String: Any] ?? [:]
        let given = { (field: String) -> String? in
            let value = info[field] as? String
            return value?.isEmpty == false ? value : nil
        }

        Keychain.accessGroup = Keychain.sharedGroupFromBundle()
        let looks = BotLooks.load()
        let profile = given("profile") ?? ""
        var sender = content.title
        if sender.isEmpty { sender = profile.isEmpty ? "Hermes" : profile }
        let label = sender.components(separatedBy: " · ")[0]
        let key = looks.key(profile: profile, label: label)
        let choice = looks.choice(key: key, profile: profile)

        bot = sender
        chatTitle = given("title") ?? content.subtitle
        text = given("text") ?? Self.withoutChatPrefix(content.body)
        look = choice.look(forProfile: profile)
        photo = choice == .photo ? key.flatMap { looks.photos[$0] }.flatMap(UIImage.init(data:)) : nil
        failed = content.categoryIdentifier == "HERMES_ERROR"
        when = notification.date
    }

    /// Banners read "chat title: reply", because older companions provide no body on its own.
    private static func withoutChatPrefix(_ body: String) -> String {
        guard let colon = body.range(of: ": "), body.distance(from: body.startIndex, to: colon.lowerBound) < 80 else { return body }
        return String(body[colon.upperBound...])
    }
}

// MARK: - The card

/// One bot message: who wrote it and when, with the words in a bubble below.
struct ReplyCard: View {
    struct Model {
        var bot: String
        var chatTitle: String
        var text: String
        var look: CharacterLookID
        /// A photo shown in place of the look, when the bot has one.
        var photo: UIImage?
        var failed: Bool
        var when: Date
    }

    var model: Model
    private let bubbleWidth: CGFloat = 300

    var body: some View {
        let insets = EdgeInsets(top: 12, leading: 22, bottom: 14, trailing: 22)
        return VStack(alignment: .leading, spacing: 10) {
            header
            messageBubble
        }
        .padding(insets)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            SenderAvatar(look: model.look, photo: model.photo, size: 42)
            SenderNames(bot: model.bot, chat: model.chatTitle)
            Spacer(minLength: 8)
            SentStamp(date: model.when, failed: model.failed)
        }
    }

    private var messageBubble: some View {
        let words = model.text.replacingOccurrences(of: "\n\n", with: "\n")
        let shape = BubbleShape()
        return ScrollView {
            Text(words)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(uiColor: .secondarySystemFill), in: shape)
        .clipShape(shape)
        .frame(maxWidth: bubbleWidth, alignment: .leading)
        .padding(.trailing, 36)
    }
}

/// The bot's name over the chat it belongs to.
private struct SenderNames: View {
    var bot: String
    var chat: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(bot).font(.headline)
            Text(chat).foregroundStyle(.secondary).font(.subheadline).lineLimit(1)
        }
    }
}

/// When it arrived, with a red note if the turn failed.
private struct SentStamp: View {
    var date: Date
    var failed: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(date, style: .time).foregroundStyle(.secondary).font(.caption)
            if failed {
                Label("Failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption2.weight(.bold))
            }
        }
    }
}

/// A Messages-style bubble whose bottom-left corner curls out into a small tail, drawn as one outline.
struct BubbleShape: Shape {
    private let radius: CGFloat = 17

    func path(in rect: CGRect) -> Path {
        let r = radius
        let (left, right, top, bottom) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        return Path { outline in
            outline.move(to: CGPoint(x: left + r, y: top))
            // Clockwise through the three round corners.
            for (corner, toward) in [(CGPoint(x: right, y: top), CGPoint(x: right, y: top + r)),
                                     (CGPoint(x: right, y: bottom), CGPoint(x: right - r, y: bottom))] {
                outline.addArc(tangent1End: corner, tangent2End: toward, radius: r)
            }
            // Along the bottom, out into the tail and back up the left side.
            outline.addLine(to: CGPoint(x: left + r, y: bottom))
            outline.addQuadCurve(to: CGPoint(x: left - 6, y: bottom), control: CGPoint(x: left + 4, y: bottom))
            outline.addQuadCurve(to: CGPoint(x: left, y: bottom - 10), control: CGPoint(x: left - 1, y: bottom - 2))
            outline.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left + r, y: top), radius: r)
            outline.closeSubpath()
        }
    }
}

/// A bot's picture, round: its photo if it has one, otherwise its look's still.
struct SenderAvatar: View {
    var look: CharacterLookID
    var photo: UIImage?
    var size: CGFloat

    var body: some View {
        Group {
            if let photo {
                Image(uiImage: photo).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(CharacterDrawing.avatarName(look)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}
