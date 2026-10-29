import SwiftUI
import NollieCore

/// A tool call opened full size: what it was asked, what came back, as text that can be
/// selected piece by piece or shared.
struct ToolCallSheet: View {
    var activity: ToolActivity
    var fullCall: String?

    var body: some View {
        ToolCallPage(title: ToolStepPresentation(activity).title, text: composedText())
    }

    /// Titled blocks separated by a blank line. With nothing to title, the plain summary.
    private func composedText() -> String {
        let blocks = ToolCallSheet.blocks(for: activity, call: fullCall)
        if blocks.isEmpty { return ToolCallSheet.nonEmpty(activity.summary) ?? "" }
        return blocks.map { "# \($0.title)\n\($0.body)" }.joined(separator: "\n\n")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func blocks(for activity: ToolActivity, call: String?) -> [(title: String, body: String)] {
        let runsCommands = activity.name == "terminal" || activity.name == "bash"
        let args = nonEmpty(activity.argsText)
        let candidates: [(String, String?)] = [
            (runsCommands ? String(localized: "Command", comment: "A heading over a shell command") : String(localized: "Arguments", comment: "A heading over a tool call's arguments"),
             nonEmpty(call)),
            (String(localized: "Arguments", comment: "A heading over a tool call's arguments"), args == call ? nil : args),
            (String(localized: "Output", comment: "A heading over what a tool returned"), nonEmpty(activity.resultText)),
        ]
        return candidates.compactMap { title, body in body.map { (title, $0) } }
    }
}

/// The page itself: selectable monospaced text under a title, with Done and Share.
private struct ToolCallPage: View {
    var title: String
    var text: String

    @Environment(\.dismiss) private var close

    var body: some View {
        NavigationStack {
            SelectableText(text: text, monospaced: true)
                .navigationBarTitleDisplayMode(.inline)
                .navigationTitle(title)
                .toolbar { buttons }
        }
    }

    @ToolbarContentBuilder private var buttons: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done", action: { close() })
        }
        ToolbarItem(placement: .primaryAction) { share }
    }

    private var share: some View {
        ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
    }
}
