import SwiftUI
import NollieCore

/// What the context menu of a bubble offers, as titles with their symbols.
enum BubbleAction {
    case copy, select, edit, reply, share

    var title: String {
        switch self {
        case .copy: String(localized: "Copy", comment: "A menu item that copies a message")
        case .select: String(localized: "Select Text")
        case .edit: String(localized: "Edit & resend")
        case .reply: String(localized: "Reply", comment: "A menu item that replies to a message")
        case .share: String(localized: "Share", comment: "A menu item that shares a message")
        }
    }

    var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .select: "selection.pin.in.out"
        case .edit: "pencil"
        case .reply: "arrowshape.turn.up.left"
        case .share: "square.and.arrow.up"
        }
    }

    var label: some View { Label(title, systemImage: symbol) }
}

/// Context menu content for a bubble: each wanted action paired with what it does.
/// Share is always a share sheet for the same text, so it needs no closure.
struct BubbleMenu: View {
    var text: String
    var steps: [(BubbleAction, () -> Void)]
    var sharing = false

    var body: some View {
        ForEach(steps.indices, id: \.self) { n in
            Button(action: steps[n].1) { steps[n].0.label }
        }
        if sharing { ShareLink(item: text) { BubbleAction.share.label } }
    }
}

/// A message you sent: a bubble on the right, with whatever pictures and files went with it.
struct PersonBubble: View {
    var text: String
    var files: [AttachmentPreview]
    var bot: String?
    var look: BubbleLook
    /// The tail appears on the final bubble of a run only.
    var tailed: Bool
    var onSelect: (String) -> Void
    var onEdit: (String) -> Void
    var onReply: (String) -> Void
    private static let thumbSide: CGFloat = 120

    /// Saved rows keep an "[User attached image: name]" marker where a picture was. The picture is
    /// fetched from the gateway's images folder and the marker is cut from the text.
    private var pictures: [MediaRef] {
        files.isEmpty ? TranscriptMedia.attachedImages(in: text, profile: bot) : []
    }

    private var shownText: String {
        pictures.isEmpty ? text : MediaScan.userTextWithoutAttachments(text)
    }

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 6) {
                attachments
                if !shownText.isEmpty { bubble }
            }
        }
    }

    @ViewBuilder private var attachments: some View {
        if !files.isEmpty { AttachmentStrip(attachments: files) }
        if !pictures.isEmpty {
            MediaThumbStrip(refs: pictures, profile: bot, side: Self.thumbSide, alignment: .trailing)
        }
    }

    private var bubble: some View {
        let outline = MessageBubbleShape(side: .trailing, tailed: tailed && look.tailed, radius: Ink.bubbleRadius)
        let fill = look.inkForMe ? Ink.ink : AppTheme.current
        return Text(shownText)
            .font(Ink.message)
            .lineSpacing(Ink.lineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(look.inkForMe ? Ink.onInk : .white)
            .inset(h: Ink.bubblePadH, v: Ink.bubblePadV)
            .background(fill, in: outline)
            .contextMenu {
                BubbleMenu(text: text, steps: [
                    (.copy, { UIPasteboard.general.string = text }),
                    (.select, { onSelect(text) }),
                    (.edit, { onEdit(text) }),
                    (.reply, { onReply(text) }),
                ], sharing: true)
            }
    }
}

/// A message sent into a turn that is still running: grey, with a line saying if it landed yet.
struct SteerBubble: View {
    var text: String
    var status: String
    var onEdit: (String) -> Void

    private var caption: String {
        status == "queued"
            ? String(localized: "Steered · queued", comment: "A message sent into a running turn, still waiting to land")
            : String(localized: "Steered", comment: "A message sent into a running turn")
    }

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 3) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .inset(h: 14, v: 9)
                    .background(Color(.systemGray4), in: MessageBubbleShape(side: .trailing))
                    .contextMenu {
                        BubbleMenu(text: text, steps: [
                            (.copy, { UIPasteboard.general.string = text }),
                            (.edit, { onEdit(text) }),
                        ])
                    }
                Label(caption, systemImage: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
