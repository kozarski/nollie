import SwiftUI

struct BoardChatContextCard: View {
    let context: BoardChatContext
    let onReturn: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("From \(context.boardName) · \(context.statusTitle)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(context.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .frame(minWidth: DeviceWords.isMac ? 28 : 44, minHeight: DeviceWords.isMac ? 28 : 44)
                    .contentShape(.rect)
                    .accessibilityLabel("Dismiss task context")
                    .accessibilityIdentifier("chat.boardContext.dismiss")
            }
            if let reason = context.reason {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Button("Back to task", systemImage: "arrow.left") { onReturn() }
                .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(.tint)
                .frame(minHeight: DeviceWords.isMac ? 28 : 44)
                .accessibilityIdentifier("chat.boardContext.return")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.boardContext")
    }
}
