import SwiftUI
import NollieCore

/// The weekly note's colour: calm, and the same on every device.
enum WeeklyInk {
    static let tint = Color.teal
    static let symbol = "calendar"
}

/// The note as a page: what is true in a few words at the top, then what is new, then each helper's week.
struct WeeklyNotePage: View {
    @Environment(AppModel.self) private var model
    private var weekly: WeeklyNoteModel { .shared }

    var body: some View {
        SettingsPage("weekly.note") {
            PageHero(symbol: WeeklyInk.symbol, title: LocalizedStringResource("Your week"), line: .verbatim(line), tint: WeeklyInk.tint, id: "weekly.hero")
            if let note = weekly.note {
                WeeklyNoteBody(note: note)
            } else if weekly.loading {
                ProgressView().controlSize(.large)
            } else {
                PageNote("Nothing to show yet.", id: "weekly.empty")
            }
        }
        .untitledPage()
        .task { await weekly.refresh(model) }
        .reloadable { await weekly.refresh(model, force: true) }
        #if DEBUG
        // For pictures of the lower part: `-nollie-demo-weekly-anchor upper|center|bottom`.
        .defaultScrollAnchor(Self.demoAnchor)
        #endif
    }

    #if DEBUG
    private static var demoAnchor: UnitPoint? {
        let words = ProcessInfo.processInfo.arguments
        guard DemoMode.isOn, let at = words.firstIndex(of: "-nollie-demo-weekly-anchor"), at + 1 < words.count else { return nil }
        return ["upper": UnitPoint(x: 0.5, y: 0.3), "center": UnitPoint.center, "bottom": .bottom][words[at + 1]]
    }
    #endif

    /// "19 to 25 Oct", then "3 helpers busy." under it. On one line a number after the dates read
    /// as part of them ("Oct. 2 helpers"), so each gets a line of its own.
    private var line: String? {
        guard let note = weekly.note else { return nil }
        return WeeklyNoteDates.range(note.since, note.until) + "\n" + note.headline
    }
}

/// What the note says, below its title: shared by the sheet, Settings and the design pictures.
struct WeeklyNoteBody: View {
    var note: WeeklyNote
    @Environment(AppModel.self) private var model
    private var weekly: WeeklyNoteModel { .shared }

    var body: some View {
        VStack(spacing: 36) {
            if !note.news.isEmpty {
                section("New this week", id: "weekly.news") {
                    ForEach(note.news) { line in WeeklyLineRow(line: line) }
                }
            }
            ForEach(note.helpers) { helper in
                WeeklyHelperSection(helper: helper)
            }
            VStack(spacing: 14) {
                if !note.quiet.isEmpty {
                    PageNote("Nothing recorded for \(WeeklyNoteDates.list(note.quiet)).", symbol: "moon.zzz", id: "weekly.quiet")
                }
                if !note.unread.isEmpty {
                    PageNote("Couldn't read \(WeeklyNoteDates.list(note.unread))'s week.", symbol: "exclamationmark.circle", id: "weekly.unread")
                }
                if let filter = note.filter {
                    PageNote(.verbatim(filter), symbol: "exclamationmark.shield", id: "weekly.filter")
                }
                if let problem = weekly.problem {
                    PageNote(.verbatim(problem), symbol: "exclamationmark.circle", tint: .orange, id: "weekly.problem")
                }
            }
        }
        .animation(.snappy, value: weekly.done)
    }

    private func section<Rows: View>(_ title: LocalizedStringResource, id: String, @ViewBuilder rows: @escaping () -> Rows) -> some View {
        VStack(spacing: 12) {
            PageHeading(title)
            GlassStack(content: rows)
        }
        .testID(id)
    }
}

/// One helper's week: its face and name with Mute, what it did, then what left the Mac.
struct WeeklyHelperSection: View {
    var helper: WeeklyNote.Helper
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            GlassStack {
                ForEach(helper.did) { line in WeeklyLineRow(line: line) }
            }
            Text(helper.leftLine)
                .font(.body)
                .foregroundStyle(Ink.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.top, helper.did.isEmpty ? 0 : 6)
                .testID("weekly.left.\(helper.profile)")
            GlassStack {
                ForEach(helper.left) { line in WeeklyLineRow(line: line) }
            }
            if helper.morePlaces > 0 {
                Text("and \(helper.morePlaces) more places", comment: "After a list of places a helper's work went")
                    .font(.subheadline)
                    .foregroundStyle(Ink.text3)
                    .padding(.horizontal, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .testID("weekly.helper.\(helper.profile)")
    }

    private var header: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                BotAvatar(profile: helper.profile, size: 40, animated: false)
                Text(helper.name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            WeeklyActionButtons(actions: [helper.mute], line: "\(helper.profile)/mute")
        }
    }
}

/// One line of the note on a glass capsule: its symbol, what happened, a quiet detail, "New" when it is, and its
/// taps. At the largest text sizes, and on a phone when there are two taps, the taps go under the words.
struct WeeklyLineRow: View {
    var line: WeeklyNote.Line
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var narrow: Bool { sizeClass == .compact }
    #else
    private let narrow = false
    #endif

    /// On a phone any line with buttons puts them under its words, so every row in the note has
    /// the same shape and no headline is squeezed into a short column beside a capsule.
    private var stacked: Bool { typeSize.isAccessibilitySize || (narrow && !line.actions.isEmpty) }
    @ScaledMetric(relativeTo: .body) private var symbolColumn: CGFloat = 26

    var body: some View {
        let large = stacked
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Image(systemName: line.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(line.isNew ? WeeklyInk.tint : Ink.text2)
                    .frame(width: symbolColumn)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(shown).font(.headline).foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                    // "New" on the quiet line, so the line's own words keep the room.
                    if line.detail != nil || tagged {
                        // Above the detail at the largest sizes, where side by side would break its words.
                        let tagLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                        tagLayout {
                            if tagged { NewTag() }
                            if let detail = line.detail {
                                Text(Self.unhyphenated(detail)).font(.subheadline).foregroundStyle(Ink.text2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityLabel(detail)
                            }
                        }
                    }
                }
            }
            if !large { Spacer(minLength: 8) }
            if !line.actions.isEmpty {
                WeeklyActionButtons(actions: line.actions, line: line.id)
                    .padding(.leading, large ? symbolColumn + 14 : 0)
            }
        }
        .padding(.leading, 20).padding(.trailing, line.actions.isEmpty ? 22 : 10).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .nollieGlass(.regular, in: shape, solid: Ink.card)
        .accessibilityElement(children: .contain)
        .testID("weekly.line.\(line.id)")
    }

    /// A capsule, or a softly rounded box once large text wraps the words onto more lines.
    private var shape: AnyShape {
        stacked ? AnyShape(.rect(cornerRadius: 26, style: .continuous)) : AnyShape(Capsule())
    }

    /// News says it is new in its words; the helper's own lines wear the tag.
    private var tagged: Bool { line.isNew && !line.id.hasPrefix("news/") }

    /// A web address in a line ("mcp.notes.example.com") may break after a dot but is never hyphenated, even in
    /// languages that hyphenate words: its letters are held together with word joiners.
    static func unhyphenated(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { word in
            guard word.split(separator: ".").count >= 3 else { return String(word) }
            return LineBreaks.address(String(word))
        }
        .joined(separator: " ")
    }

    /// A place's host may break only after a dot, never inside a word.
    private var shown: String {
        line.kind == .place && !line.text.contains(" ") ? line.text.replacingOccurrences(of: ".", with: ".\u{200B}") : line.text
    }
}

/// "New", in the note's colour.
struct NewTag: View {
    var body: some View {
        Text("New")
            .font(.caption.weight(.bold))
            .foregroundStyle(WeeklyInk.tint)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(WeeklyInk.tint.opacity(0.16), in: Capsule())
            .fixedSize()
            .accessibilityLabel("New this week")
    }
}

/// A line's taps as small glass capsules. Once one is done the line says so, with Undo beside it. Remove asks
/// first, and has no undo.
struct WeeklyActionButtons: View {
    var actions: [WeeklyAction]
    var line: String
    @Environment(AppModel.self) private var model
    @State private var confirming: WeeklyAction?
    @Environment(\.dynamicTypeSize) private var typeSize
    private var weekly: WeeklyNoteModel { .shared }

    var body: some View {
        // Side by side when they fit; one above the other when longer words or large text would push past the edge.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 8) { content }
        }
        .disabled(weekly.busy.contains(line) || model.lock.isLocked)
        .confirmationDialog(confirmTitle, isPresented: .present($confirming), titleVisibility: .visible) {
            if let action = confirming {
                Button(action.label, role: .destructive) { run(action) }
                    .testID("weekly.confirm")
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text("This can't be undone.", comment: "Safety: under the question before removing a schedule or a connected app; keep exact meaning")
        }
        #if DEBUG
        .task {
            // For pictures: `-nollie-demo-weekly-ask <line id>` asks that line's Remove question, as a tap would.
            let words = ProcessInfo.processInfo.arguments
            guard DemoMode.isOn, let at = words.firstIndex(of: "-nollie-demo-weekly-ask"), at + 1 < words.count,
                  words[at + 1] == line, let action = actions.first(where: \.asksFirst) else { return }
            try? await Task.sleep(for: .seconds(2))
            confirming = action
        }
        #endif
    }

    @ViewBuilder private var content: some View {
        if let done = weekly.done[line] {
            Label(done.done, systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Ink.text2)
                .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
                .testID("weekly.done.\(line)")
            if let undo = done.undo {
                button(undo, title: String(localized: "Undo"))
            }
        } else {
            ForEach(actions, id: \.self) { action in button(action, title: action.label) }
        }
        if weekly.busy.contains(line) { ProgressView().controlSize(.small) }
    }

    private var confirmTitle: String {
        switch confirming {
        case .remove?: return String(localized: "Remove this schedule?", comment: "Safety: asks before removing a schedule")
        case .removeApp(let bot, let app)?:
            let helper = model.runtime?.profiles.first { $0.name == bot }?.shownName ?? ProfileInfo.shownName(of: bot)
            return String(localized: "Remove \u{201C}\(app)\u{201D} from \(helper)?",
                          comment: "Safety: asks before taking a connected app away from a helper; the app, then the helper. Keep exact meaning")
        default: return ""
        }
    }

    private func button(_ action: WeeklyAction, title: String) -> some View {
        Button {
            if action.asksFirst { confirming = action } else { run(action) }
        } label: {
            // One line on the capsule; at the largest sizes a longer word ("Stummschalten") may wrap instead of
            // pushing the page past the screen's edge.
            Text(title).font(.subheadline.weight(.semibold))
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
        }
        .buttonStyle(.nollieGlass)
        .buttonBorderShape(.capsule)
        // A full-size capsule on the phone, where a small one is too short for a fingertip.
        #if os(iOS)
        .controlSize(.regular)
        #else
        .controlSize(.small)
        #endif
        .tint(action.asksFirst ? .red : nil)
        .accessibilityLabel(title)
        .testID("weekly.action.\(line).\(title)")
    }

    private func run(_ action: WeeklyAction) {
        Task { await weekly.perform(action, line: line, model: model) }
    }
}

/// The note in a sheet, from its card or its notification.
struct WeeklyNoteSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WeeklyNotePage()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.testID("weekly.done")
                    }
                }
        }
        .sheetFrame(.wide)
    }
}

/// Dates and names as the note says them.
enum WeeklyNoteDates {
    /// "19 to 25 Oct", or "28 Oct to 3 Nov" across a month.
    static func range(_ from: Date, _ to: Date, calendar: Calendar = .current) -> String {
        // Other languages order a range their own way ("21.–27. Okt.", "10月21日～27日").
        if Bundle.main.preferredLocalizations.first?.hasPrefix("en") == false, from <= to {
            return (from..<to).formatted(.interval.day().month(.abbreviated))
        }
        let sameMonth = calendar.isDate(from, equalTo: to, toGranularity: .month)
        let start = sameMonth ? from.formatted(.dateTime.day()) : from.formatted(.dateTime.day().month(.abbreviated))
        return String(localized: "\(start) to \(to.formatted(.dateTime.day().month(.abbreviated)))", comment: "A range of two dates")
    }

    /// "Mason", "Mason and Forager", "Scout, Mason and Forager".
    static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.joined() }
        let head = names.dropLast().joined(separator: String(localized: ", ", comment: "Separates names in a list"))
        return String(localized: "\(head) and \(last)", comment: "The end of a list of names: Scout, Mason and Forager")
    }
}
