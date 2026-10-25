import SwiftUI
import NollieCore

/// A stretch of consecutive tool calls under one disclosure. Each step keeps its own details.
struct ToolRunRow: View, Equatable {
    static func == (lhs: ToolRunRow, rhs: ToolRunRow) -> Bool {
        lhs.items == rhs.items
            && lhs.open.wrappedValue == rhs.open.wrappedValue
            && lhs.openSteps == rhs.openSteps
            && lhs.showToolOutput == rhs.showToolOutput
            && lhs.maxBubble == rhs.maxBubble
    }

    var items: [TranscriptItem]
    var open: Binding<Bool>
    var openSteps: Set<String>
    var setStepOpen: (String, Bool) -> Void
    var showToolOutput = true
    var maxBubble: CGFloat = .infinity
    private let hold = DisclosureHold()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var steps: [ToolActivity] {
        items.compactMap { entry in
            guard case .tool(let activity) = entry.kind else { return nil }
            return activity
        }
    }
    private var running: ToolActivity? { steps.last { $0.status == .running } }
    private var failed: Int { steps.filter { $0.status == .failed }.count }
    private var title: String {
        guard let running else { return ToolStepPresentation.summary(steps) }
        return ToolStepPresentation(running).title
    }

    /// Time for the whole run: first start to final finish, or the sum of the steps if that is more.
    private var seconds: Double {
        guard let first = items.first, let last = items.last else { return 0 }
        let tail = steps.last?.durationSeconds ?? 0
        let wall = last.timestamp.addingTimeInterval(tail).timeIntervalSince(first.timestamp)
        return max(wall, steps.compactMap(\.durationSeconds).reduce(0, +))
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        return "\(Int((seconds / 60).rounded())) min"
    }

    private var detail: String {
        var parts = ["\(steps.count) step" + (steps.count == 1 ? "" : "s")]
        if seconds >= 1, running == nil { parts.append(Self.duration(seconds)) }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    private var isOpen: Bool { open.wrappedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen { stepList }
        }
        .frame(maxWidth: isOpen ? maxBubble : nil, alignment: .leading)
        .holdingHeader(hold, id: items.first?.id)
        .nollieGlass(.regular, in: .rect(cornerRadius: isOpen ? 20 : 22))
        .accessibilityElement(children: .contain)
        .spread()
    }

    private func stepBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { openSteps.contains(id) }, set: { setStepOpen(id, $0) })
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().inset(h: 14)
            ForEach(items) { entry in
                if case .tool(let activity) = entry.kind {
                    ToolCardView(activity: activity, itemID: entry.id, open: stepBinding(entry.id),
                                 showOutput: showToolOutput, compact: true)
                }
            }
            Text(detail).quiet(.caption).inset(h: 10).padding(.top, 6).padding(.bottom, 8)
        }
        .padding(6)
        .transition(.opacity)
    }

    private var header: some View {
        PlainButton {
            hold.begin(id: items.first?.id)
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) { open.wrappedValue.toggle() }
        } label: {
            headerRow
        }
        .accessibilityLabel(title)
        .accessibilityValue((isOpen ? "Expanded" : "Collapsed") + ", " + detail)
        .accessibilityHint(isOpen ? "Hides the steps" : "Shows each step")
        .accessibilityIdentifier("thread.steps")
    }

    private var headerRow: some View {
        HStack(spacing: 9) {
            HStack(spacing: 5) {
                ForEach(ToolStepPresentation.symbols(steps), id: \.self) { Glyph($0, .callout) }
            }
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.medium)).lineLimit(2)
            if isOpen { Spacer(minLength: 6) }
            trailingMark.accessibilityHidden(true)
            Text("\(steps.count)").quiet(.caption.monospacedDigit()).accessibilityHidden(true)
            Glyph("chevron.right", .caption2.weight(.semibold), .secondary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .accessibilityHidden(true)
        }
        .inset(h: 14, v: 8)
        .frame(minHeight: DeviceWords.isMac ? 36 : 44)
        .frame(maxWidth: isOpen ? .infinity : nil, alignment: .leading)
        .contentShape(.rect)
    }

    @ViewBuilder private var trailingMark: some View {
        if running != nil {
            ProgressView().controlSize(.mini)
        } else if failed > 0 {
            Glyph("exclamationmark.circle", .body, .orange)
        }
    }
}

/// One tool call: a line saying what it is, with the details underneath once opened.
struct ToolCardView: View {
    var activity: ToolActivity
    var itemID: String? = nil
    var open: Binding<Bool> = Binding.constant(false)
    var showOutput: Bool = true
    /// Inside a run, rows share the run's surface; a lone action gets its own glass.
    var compact: Bool = false
    @State private var showFull: Bool = false
    private let hold = DisclosureHold()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expanded: Bool { open.wrappedValue }
    private var presentation: ToolStepPresentation { ToolStepPresentation(activity) }
    private var identity: String { itemID ?? activity.id }
    private var todos: [TodoItem]? {
        let (tool, args) = (activity.name, activity.argsText)
        return TodoItem.parse(name: tool, argsText: args)
    }
    private var isShell: Bool { ["terminal", "bash"].contains(activity.name) }
    private var minRowHeight: CGFloat { DeviceWords.isMac ? 36 : 44 }

    /// What was run: the command for a shell tool, otherwise the raw arguments, otherwise context.
    private var fullCall: String? {
        guard let args = activity.argsText, !args.isEmpty else { return activity.context }
        let parsed = try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any]
        return (parsed?["command"] as? String) ?? args
    }

    private var status: String {
        switch activity.status {
        case .running: "Running"
        case .done: "Completed"
        case .failed: "Failed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded { details }
        }
        .spread()
        .modifier(ActivityStepSurface(compact: compact))
        .sheet(isPresented: $showFull) {
            ToolCallSheet(activity: activity, fullCall: fullCall).sheetFrame(.wide).withAppModel()
        }
        .holdingHeader(hold, id: itemID)
        .accessibilityElement(children: .contain)
    }

    private func toggle() {
        hold.begin(id: itemID)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) { open.wrappedValue.toggle() }
    }

    private var header: some View {
        PlainButton(action: toggle) { headerRow }
            .accessibilityLabel(presentation.title + (presentation.detail.map { ", " + $0 } ?? ""))
            .accessibilityValue((expanded ? "Expanded" : "Collapsed") + ", " + status)
            .accessibilityHint(expanded ? "Hides this step’s details" : "Shows this step’s details")
            .accessibilityIdentifier("activity.step.\(identity)")
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Glyph(presentation.symbol, .callout, .secondary).frame(width: 22).accessibilityHidden(true)
            titles
            Spacer(minLength: 4)
            if let seconds = activity.durationSeconds {
                Text(ToolRunRow.duration(seconds)).quiet(.caption.monospacedDigit(), .tertiary)
            }
            statusIcon.accessibilityHidden(true)
            Glyph("chevron.right", .caption2.weight(.semibold), .tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .inset(h: 10, v: 9)
        .frame(minHeight: minRowHeight)
        .spread()
        .contentShape(.rect)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(presentation.title).quiet(.subheadline.weight(.medium), .primary)
            if let line = presentation.detail {
                Text(line).quiet(.caption).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func caption(_ words: String, _ symbol: String) -> some View {
        Label(words, systemImage: symbol).quiet(.caption.weight(.medium))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let risk = activity.risk { Label(risk, systemImage: "exclamationmark.shield").quiet(.caption, .orange) }
            if let summary = activity.summary, !summary.isEmpty {
                Text(summary).font(.subheadline).textSelection(.enabled)
            }
            callSection
            if showOutput, let result = activity.resultText, !result.isEmpty { output(result) }
            fullDetailsButton
        }
        .padding(12)
        .spread()
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        .inset(h: 8)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.details.\(identity)")
        .transition(.opacity)
    }

    @ViewBuilder private var callSection: some View {
        if let todos {
            TodoChecklist(items: todos, all: true)
        } else if let call = fullCall, !call.isEmpty {
            caption(isShell ? "Command" : "Details", presentation.symbol)
            CodeBlock(text: call, lineCap: 12)
        }
    }

    private var fullDetailsButton: some View {
        Button { showFull = true } label: {
            Label("Full details", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.caption)
                .frame(minHeight: DeviceWords.isMac ? 28 : 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("activity.full.\(identity)")
    }

    /// The tool's output, with any screenshots or recordings it mentions shown below.
    @ViewBuilder private func output(_ result: String) -> some View {
        caption("Output", "text.alignleft")
        CodeBlock(text: result, lineCap: 12)
        let pictures = MediaScan.imagePaths(inToolOutput: result)
        if !pictures.isEmpty { MediaThumbStrip(refs: pictures, profile: nil, side: 110) }
        let videos = MediaScan.videoPaths(inToolOutput: result)
        if !videos.isEmpty { VideoCardStrip(refs: videos, profile: nil) }
    }

    @ViewBuilder private var statusIcon: some View {
        switch activity.status {
        case .failed: Glyph("exclamationmark.circle.fill", .caption, .orange)
        case .done: Glyph("checkmark", .caption2, .tertiary)
        case .running: ProgressView().controlSize(.mini)
        }
    }
}

/// Gives a step its own glass card unless it sits inside a run.
private struct ActivityStepSurface: ViewModifier {
    var compact: Bool

    func body(content: Content) -> some View {
        if compact { content } else { content.nollieGlass(.regular, in: .rect(cornerRadius: 18)) }
    }
}
