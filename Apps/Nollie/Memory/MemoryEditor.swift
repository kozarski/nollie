import SwiftUI
import NollieCore

/// Writing one remembered thing: a new one for "About you", or a change to the one opened, which can
/// also be forgotten from here. The check mark saves. If it changed on the Mac first, the words stay
/// here and the next save keeps them.
struct MemoryEditor: View {
    @State var draft: HelperMemoryModel.Draft
    var label: String
    var memory: HelperMemoryModel

    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var note: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                editor
                if let note {
                    PageNote(note, symbol: "exclamationmark.triangle.fill", tint: .orange, id: "memory.editor.note")
                }
                if let original = draft.original {
                    GlassButton("Forget", symbol: "trash", role: .destructive, id: "memory.editor.forget") {
                        memory.forget(original, in: draft.kind)
                        dismiss()
                    }
                }
            }
            .padding(EdgeInsets(top: 12, leading: 24, bottom: 24, trailing: 24))
            .frame(maxWidth: 560)
            .spread(.center)
            .background(Ink.canvas.ignoresSafeArea())
            .navigationTitle(draft.isNew ? "Remember" : "Edit")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { buttons }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(saving)
    }

    private var editor: some View {
        TextEditor(text: $draft.text)
            .font(.body)
            .foregroundStyle(Ink.text)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .frame(minHeight: 120)
            .overlay(alignment: .topLeading) { placeholder }
            .testID("memory.editor.text")
    }

    @ViewBuilder private var placeholder: some View {
        if draft.text.isEmpty {
            Text("Something \(label) should know about you")
                .font(.body)
                .foregroundStyle(Ink.text3)
                .padding(EdgeInsets(top: 8, leading: 5, bottom: 0, trailing: 0))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ToolbarContentBuilder private var buttons: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", systemImage: "xmark") { dismiss() }
                .disabled(saving)
                .testID("memory.editor.cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(action: save) {
                if saving { ProgressView() } else { Image(systemName: "checkmark") }
            }
            .disabled(saving || !draft.canSave)
            .accessibilityLabel(draft.isNew ? "Remember" : "Save")
            .testID("memory.editor.save")
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            switch await memory.save(draft) {
            case .saved:
                dismiss()
            case .changed(let kept):
                draft = kept
                note = kept.isNew ? "This changed on your Mac. Save again to keep yours."
                                  : "This changed on your Mac. Check it and save again."
            case .refused(let words):
                note = words
            case .failed:
                note = "Couldn't save. Try again."
            }
        }
    }
}
