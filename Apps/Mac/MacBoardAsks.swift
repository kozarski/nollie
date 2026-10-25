import SwiftUI

extension View {
    /// Adds the Board's questions and notices, shown as dialogs, to this view.
    @MainActor
    func kanbanAsks(ask pending: Binding<KanbanAsk?>, answer: Binding<String>, notice: Binding<String?>,
                    answerAsk: @escaping @MainActor (KanbanAsk) async -> Void) -> some View {
        self.modifier(KanbanAskPresenter(submit: answerAsk, notice: notice, ask: pending, answer: answer))
    }
}

/// The Board's questions and notices as dialogs. The words come from `KanbanAsk`, which the phone
/// shares, so both screens ask the same thing.
private struct KanbanAskPresenter: ViewModifier {
    let submit: @MainActor (KanbanAsk) async -> Void
    @Binding var notice: String?
    @Binding var ask: KanbanAsk?
    @Binding var answer: String

    /// A switch that reads from the pending ask and closes it by emptying it.
    private func open(when kindMatches: @escaping (KanbanAsk) -> Bool) -> Binding<Bool> {
        Binding(
            get: { ask.map(kindMatches) ?? false },
            set: { if !$0 { ask = nil } })
    }

    private var noticeOpen: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    func body(content: Content) -> some View {
        content
            .alert(ask?.title ?? "", isPresented: open(when: \.asksForText)) {
                if let pending = ask {
                    TextField(pending.placeholder, text: $answer)
                    send(pending)
                    Button("Cancel", role: .cancel) { ask = nil }
                }
            } message: {
                Text(ask?.message ?? "")
            }
            .confirmationDialog(ask?.title ?? "", isPresented: open(when: { !$0.asksForText }),
                                titleVisibility: .visible) {
                if let pending = ask {
                    send(pending)
                    Button("Cancel", role: .cancel) { ask = nil }
                }
            } message: {
                Text(ask?.message ?? "")
            }
            .alert("Board", isPresented: noticeOpen) {
                Button("OK") { notice = nil }
            } message: {
                Text(notice ?? "")
            }
    }

    private func send(_ pending: KanbanAsk) -> some View {
        Button(pending.verb, role: pending.destructive ? .destructive : nil) {
            Task { await submit(pending) }
        }
    }
}
