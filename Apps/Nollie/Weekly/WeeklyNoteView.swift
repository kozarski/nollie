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
            PageHero(symbol: WeeklyInk.symbol, title: "Your week", line: line, tint: WeeklyInk.tint, id: "weekly.hero")
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
        // For pictures of the lower part: `-nollie-demo-weekly-anchor center|bottom`.
        .defaultScrollAnchor(Self.demoAnchor)
        #endif
    }

    #if DEBUG
    private static var demoAnchor: UnitPoint? {
        let words = ProcessInfo.processInfo.arguments
        guard DemoMode.isOn, let at = words.firstIndex(of: "-nollie-demo-weekly-anchor"), at + 1 < words.count else { return nil }
        return ["center": UnitPoint.center, "bottom": .bottom][words[at + 1]]
    }
    #endif

    /// "19 to 25 Oct. 3 helpers busy."
    private var line: String? {
        guard let note = weekly.note else { return nil }
        return WeeklyNoteDates.range(note.since, note.until) + ". " + note.headline
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
                    PageNote(filter, symbol: "exclamationmark.shield", id: "weekly.filter")
                }
                if let problem = weekly.problem {
                    PageNote(problem, symbol: "exclamationmark.circle", tint: .orange, id: "weekly.problem")
                }
            }
        }
        .animation(.snappy, value: weekly.done)
    }

    private func section<Rows: View>(_ title: String, id: String, @ViewBuilder rows: @escaping () -> Rows) -> some View {
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
                Text(helper.morePlaces == 1 ? "and 1 more place" : "and \(helper.morePlaces) more places")
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
            if HelperMute.offered(for: helper.profile) {
                WeeklyActionButtons(actions: [helper.mute], line: "\(helper.profile)/mute")
            }
        }
    }
}

/// One line of the note on a glass capsule: its symbol, what happened, a quiet detail, "New" when it is, and its
/// taps. At the largest text sizes the taps go under the words.
struct WeeklyLineRow: View {
    var line: WeeklyNote.Line
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let large = typeSize.isAccessibilitySize
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Image(systemName: line.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(line.isNew ? WeeklyInk.tint : Ink.text2)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(shown).font(.headline).foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                    // "New" on the quiet line, so the line's own words keep the room.
                    if line.detail != nil || tagged {
                        // Above the detail at the largest sizes, where side by side would break its words.
                        let tagLayout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                        tagLayout {
                            if tagged { NewTag() }
                            if let detail = line.detail {
                                Text(detail).font(.subheadline).foregroundStyle(Ink.text2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            if !large { Spacer(minLength: 8) }
            if !line.actions.isEmpty {
                WeeklyActionButtons(actions: line.actions, line: line.id)
                    .padding(.leading, large ? 40 : 0)
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
        typeSize.isAccessibilitySize ? AnyShape(.rect(cornerRadius: 26, style: .continuous)) : AnyShape(Capsule())
    }

    /// News says it is new in its words; the helper's own lines wear the tag.
    private var tagged: Bool { line.isNew && !line.id.hasPrefix("news/") }

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
    private var weekly: WeeklyNoteModel { .shared }

    var body: some View {
        HStack(spacing: 8) {
            if let done = weekly.done[line] {
                Label(done.done, systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Ink.text2)
                    .fixedSize()
                    .testID("weekly.done.\(line)")
                if let undo = done.undo {
                    button(undo, title: "Undo")
                }
            } else {
                ForEach(actions, id: \.self) { action in button(action, title: action.label) }
            }
            if weekly.busy.contains(line) { ProgressView().controlSize(.small) }
        }
        .disabled(weekly.busy.contains(line) || model.lock.isLocked)
        .confirmationDialog(confirmTitle, isPresented: .present($confirming), titleVisibility: .visible) {
            if let action = confirming {
                Button(action.label, role: .destructive) { run(action) }
                    .testID("weekly.confirm")
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var confirmTitle: String {
        guard case .remove? = confirming else { return "" }
        return "Remove this schedule?"
    }

    private func button(_ action: WeeklyAction, title: String) -> some View {
        Button {
            if action.asksFirst { confirming = action } else { run(action) }
        } label: {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
        }
        .buttonStyle(.nollieGlass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
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
        let sameMonth = calendar.isDate(from, equalTo: to, toGranularity: .month)
        let start = sameMonth ? from.formatted(.dateTime.day()) : from.formatted(.dateTime.day().month(.abbreviated))
        return "\(start) to \(to.formatted(.dateTime.day().month(.abbreviated)))"
    }

    /// "Mason", "Mason and Forager", "Scout, Mason and Forager".
    static func list(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}
