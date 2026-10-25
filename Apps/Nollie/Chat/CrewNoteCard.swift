import SwiftUI
import NollieCore

/// Appears in the chat when Nollie adds, changes or suggests a crew member. Shows its note and
/// what changed, with Meet and Undo (or Add and Not now). The buttons call the crew add-on
/// directly, so your answer never goes through the model.
struct CrewNoteCard: View {
    var note: CrewNote
    var onOpenBot: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var answered: String?
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            intro
            outcome
            if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
        }
        .padding(16)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Ink.card, in: .rect(cornerRadius: Ink.cardRadius, style: .continuous))
        .spread()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("crew.note")
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: 10) {
            BotAvatar(profile: note.profile ?? "", size: 30, animated: false)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(note.note).font(.body).fixedSize(horizontal: false, vertical: true)
                if !note.changes.isEmpty {
                    Text(note.changes.joined(separator: " · "))
                        .fixedSize(horizontal: false, vertical: true)
                        .quiet(.caption)
                }
            }
        }
    }

    /// Either what was answered, or the buttons that are still on offer.
    @ViewBuilder private var outcome: some View {
        if let answered {
            Label(answered, systemImage: "checkmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("crew.answered")
        } else if !note.actions.isEmpty {
            HStack(spacing: 8) {
                ForEach(note.actions) { action in
                    Button(action.label) { tap(action) }
                        .buttonStyle(OutlinePillStyle())
                        .disabled(busy)
                        .accessibilityIdentifier("crew.\(action.kind.rawValue)")
                }
                if busy { ProgressView().controlSize(.small) }
            }
        }
    }

    private func tap(_ action: CrewNote.Action) {
        guard action.kind != .meet else {
            return onOpenBot(action.profile ?? note.profile ?? "")
        }
        (busy, problem) = (true, nil)
        Task {
            defer { busy = false }
            do {
                guard let runtime = model.runtime else { throw URLError(.notConnectedToInternet) }
                let result = try await runtime.answerCrew(action)
                answered = result.note ?? (action.kind == .undo ? "Undone" : "Done")
            } catch {
                problem = "That didn't go through. Try again."
            }
        }
    }
}
