import SwiftUI
import NollieCore

/// Lets the person rename a chat. It opens with the old name selected and focused, so the first
/// keystroke replaces it; Return saves, Escape cancels. A sheet, not an alert, because the Mac
/// cannot focus an alert's text field. Reached through the chat menu, by long-pressing the title,
/// and from the Name row of the bot card.
struct RenameChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool
    @State private var draft = ""
    @Bindable var chat: ChatSession

    private var name: String {
        draft.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    var body: some View {
        content
            .padding(20)
            .frame(minWidth: 320)
            .onAppear(perform: begin)
            .modifier(RenameSheetShape())
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename chat").font(Font.headline)
            nameField
            Text("Shown in your chat list and at the top of the chat.").quiet(.footnote)
            buttons
        }
    }

    private func begin() {
        draft = chat.title
        typing = true
    }

    private var nameField: some View {
        TextField("Name", text: $draft)
            .focused($typing)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("rename.name")
            .onSubmit(save)
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(role: .cancel) {
                dismiss()
            } label: {
                Text("Cancel")
            }
            .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func save() {
        guard !name.isEmpty else { return }
        let renamed = name
        Task { await chat.rename(renamed) }
        dismiss()
    }
}

/// Sheet size and, on the phone, selecting the old name as soon as the field starts editing.
private struct RenameSheetShape: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .presentationDragIndicator(.hidden)
            .presentationDetents([.height(220)])
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { note in
                // With everything selected, the first key typed replaces the old name.
                (note.object as? UITextField)?.selectAll(nil)
            }
        #else
        content
        #endif
    }
}

extension View {
    /// Presents the rename sheet for `chat` whenever `isPresented` is on and there is a chat.
    func renameSheet(for chat: ChatSession?, isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            if let chat {
                RenameChatSheet(chat: chat)
                    .sheetFrame(.compact)
                    .withAppModel()
            }
        }
    }
}
