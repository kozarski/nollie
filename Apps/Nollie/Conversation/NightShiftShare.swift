import SwiftUI
import UniformTypeIdentifiers
import NollieCore

/// The night shift card as the shared picture draws it. Every personal part of a run's title or an action's
/// target (`PrivateDetails`) is replaced here by marks of the same length, so the picture never holds the words;
/// bot names, receipt words, times and counts stay as they are.
struct NightShiftShareModel: Equatable {
    struct Piece: Equatable {
        var text: String
        var hidden: Bool
    }

    struct Action: Equatable {
        var verb: String
        var target: [Piece]
        var receipt: String
        var warn: Bool
    }

    struct Run: Equatable, Identifiable {
        var id: String
        var bot: String
        var title: [Piece]
        var line: String
        var actions: [Action]
        /// Actions past the ones drawn.
        var more: Int
    }

    var window: String?
    var counts: String
    /// When the Mac was asleep: times and counts only.
    var sleep: String?
    var unwatched: String?
    var runs: [Run]
    /// "12 more runs not listed", on a night with more runs than the card lists.
    var moreRuns: String?

    /// The most actions a run draws in the picture.
    static let actionsPerRun = 8
    static let mark: Character = "•"

    init(_ card: ConversationPost.NightShift, now: Date = Date()) {
        window = card.from.map { NightShiftWords.since($0, now: now) }
        counts = NightShiftWords.counts(card.counts)
        sleep = SleepNote.line(for: card)
        unwatched = card.unwatched.isEmpty ? nil : NightShiftWords.unwatched(card.unwatched)
        runs = card.runs.map { run in
            Run(id: run.id, bot: run.bot, title: Self.pieces(NightShiftWords.title(of: run)), line: NightShiftWords.runLine(run),
                actions: run.actions.prefix(Self.actionsPerRun).map { action in
                    Action(verb: NightShiftWords.verb(action), target: Self.target(of: action),
                           receipt: NightShiftWords.receipt(action, in: run), warn: action.status == .blocked)
                },
                more: max(run.actions.count - Self.actionsPerRun, 0) + run.more)
        } + card.missed.map { missed in
            Run(id: "missed:\(missed.bot):\(missed.jobId)", bot: missed.bot, title: Self.pieces(missed.title.isEmpty ? "Schedule" : missed.title),
                line: NightShiftWords.missedLine(missed), actions: [], more: 0)
        }
        moreRuns = card.moreRuns > 0 ? NightShiftWords.moreRuns(card.moreRuns) : nil
    }

    /// An action's target as pieces. A web page's address is personal however it is written, so for the tools that
    /// open one the whole target is marks.
    static func target(of action: ConversationPost.Action) -> [Piece] {
        // A held action's target is its whole summary (who it was for, what it said): the picture keeps the first line.
        if NightShiftWords.heldByAskFirst(action) {
            return pieces(String(action.target.split(separator: "\n", omittingEmptySubsequences: true).first ?? ""))
        }
        guard !action.target.isEmpty, opensPages(action.tool) else { return pieces(action.target) }
        return [Piece(text: String(repeating: mark, count: action.target.count), hidden: true)]
    }

    static func opensPages(_ tool: String) -> Bool {
        ["web_extract", "vision_analyze"].contains(tool) || tool.hasPrefix("browser_")
    }

    /// `text` with its personal parts as marks, one for each character.
    static func pieces(_ text: String) -> [Piece] {
        PrivateDetails.segments(of: text).map { segment in
            Piece(text: segment.isPrivate ? String(repeating: mark, count: segment.text.count) : segment.text, hidden: segment.isPrivate)
        }
    }

    /// Every word the picture holds.
    var words: [String] {
        var out = [window, counts, sleep, unwatched, moreRuns].compactMap { $0 }
        for run in runs {
            out.append(run.title.map(\.text).joined())
            out.append(run.line)
            for action in run.actions {
                out += [action.verb, action.target.map(\.text).joined(), action.receipt]
            }
        }
        return out
    }
}

/// The picture that is shared: the same night sky, drawn bots, a
/// fixed width and text size, and personal parts as blurred marks.
struct NightShiftShareView: View {
    let model: NightShiftShareModel

    static let width: CGFloat = 390

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NightShiftHeading(window: model.window)
            Text(model.counts).font(Ink.cardBody).foregroundStyle(NightShiftInk.text)
            if let sleep = model.sleep {
                Text(sleep).font(Ink.cardBody).foregroundStyle(NightShiftInk.text).fixedSize(horizontal: false, vertical: true)
            }
            if let unwatched = model.unwatched {
                Text(unwatched).font(Ink.cardBody).foregroundStyle(NightShiftInk.warning)
            }
            ForEach(model.runs) { run in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Self.face(run.bot)
                        VStack(alignment: .leading, spacing: 1) {
                            Self.text(run.title).font(Ink.cardBody.weight(.semibold)).foregroundStyle(NightShiftInk.text)
                            Text(run.line).font(Ink.stamp).foregroundStyle(NightShiftInk.detail)
                        }
                    }
                    ForEach(Array(run.actions.enumerated()), id: \.offset) { _, action in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Text(action.verb.isEmpty ? "" : action.verb + " ").foregroundStyle(NightShiftInk.text))\(Self.text(action.target).font(Ink.code11).foregroundStyle(NightShiftInk.detail))")
                                .font(Ink.cardBody)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(action.receipt).font(Ink.stamp).foregroundStyle(action.warn ? NightShiftInk.warning : NightShiftInk.detail)
                        }
                        .padding(.leading, PostBotLine.indent)
                    }
                    if run.more > 0 {
                        Text("\(run.more) more").font(Ink.stamp).foregroundStyle(NightShiftInk.detail)
                            .padding(.leading, PostBotLine.indent)
                    }
                }
            }
            if let moreRuns = model.moreRuns {
                Text(moreRuns).font(Ink.stamp).foregroundStyle(NightShiftInk.detail)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            NightShiftSky().clipShape(.rect(cornerRadius: Ink.cardRadius, style: .continuous))
        }
        .padding(16)
        .frame(width: Self.width)
        .background(Ink.canvas)
        .textRenderer(PersonalMarks())
    }

    /// A bot's drawn face, never the person's photo of it.
    static func face(_ bot: String) -> BotAvatar {
        BotAvatar(profile: bot, size: PostBotLine.face, animated: false, photos: false)
    }

    /// The pieces as one text, the hidden ones marked for `PersonalMarks`.
    static func text(_ pieces: [NightShiftShareModel.Piece]) -> Text {
        var out = Text(verbatim: "")
        for piece in pieces {
            let part = Text(verbatim: piece.text)
            out = Text("\(out)\(piece.hidden ? part.customAttribute(PersonalMark()) : part)")
        }
        return out
    }

    /// The picture at `scale`, as a PNG, or nil when it could not be drawn.
    @MainActor
    static func render(_ card: ConversationPost.NightShift, scheme: ColorScheme, scale: CGFloat,
                       reduceTransparency: Bool = false) -> (image: UIImage, png: Data)? {
        let renderer = ImageRenderer(content: NightShiftShareView(model: NightShiftShareModel(card))
            .environment(\.colorScheme, scheme)
            .environment(\.nightSkySolid, reduceTransparency)
            .dynamicTypeSize(.large))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        guard let image = renderer.uiImage, let png = image.pngData() else { return nil }
        return (image, png)
    }
}

/// Text that stands for a personal part.
struct PersonalMark: TextAttribute {}

/// Draws text with its personal parts' marks blurred on a soft band.
struct PersonalMarks: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard run[PersonalMark.self] != nil else {
                    context.draw(run)
                    continue
                }
                let box = run.typographicBounds.rect
                context.fill(Path(roundedRect: box.insetBy(dx: -2, dy: 1), cornerRadius: box.height / 2), with: .color(NightShiftInk.control))
                var blurred = context
                blurred.addFilter(.blur(radius: 3))
                blurred.draw(run)
            }
        }
    }
}

/// The picture as a file to share.
struct NightShiftPicture: Transferable {
    let png: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.png }
            .suggestedFileName("Night shift.png")
    }
}

/// The sheet behind the card's Share button: the picture that will be shared, then Share. Nothing leaves the device
/// until the person picks where.
struct NightShiftShareSheet: View {
    let post: ConversationPost
    @Environment(\.displayScale) private var scale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var picture: NightShiftPicture?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Share a picture").font(Ink.cardTitle).foregroundStyle(Ink.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Ink.text)
                        .frame(width: 36, height: 36)
                        .nollieGlass(.regular.interactive(), in: Circle(), solid: Ink.canvas)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("share.close")
            }
            if let image, let picture {
                ScrollView {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: NightShiftShareView.width)
                        .accessibilityLabel("The picture to share, with personal details blurred")
                        .accessibilityIdentifier("share.preview")
                }
                Text("Personal details are blurred. Nothing is sent until you pick where.")
                    .font(Ink.stamp).foregroundStyle(Ink.text3).multilineTextAlignment(.center)
                ShareLink(item: picture, preview: SharePreview("Night shift", image: Image(uiImage: image))) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(InkPillStyle(fill: true))
                .accessibilityIdentifier("share.send")
            } else if failed {
                Text("Couldn't make the picture. Try again in a moment.").font(Ink.cardBody).foregroundStyle(Ink.text2)
                Spacer()
            } else {
                ProgressView()
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Ink.canvas)
        .task(id: scheme) { draw() }
        .onChange(of: reduceTransparency) { draw() }
    }

    private func draw() {
        guard let card = post.nightShift,
              let made = NightShiftShareView.render(card, scheme: scheme, scale: scale, reduceTransparency: reduceTransparency) else {
            failed = true
            return
        }
        image = made.image
        picture = NightShiftPicture(png: made.png)
    }
}
