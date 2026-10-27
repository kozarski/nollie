import SwiftUI
import NollieCore

/// A look at what fills the model's context: one bar, a line per category, then this chat's usage.
struct ContextBreakdownSheet: View {
    var chat: ChatSession

    @State private var breakdown: ContextBreakdown?
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsList {
                if let breakdown {
                    Section { BreakdownGauge(breakdown: breakdown, tint: Self.colour(of:)) }
                    Section("By category") { ForEach(breakdown.categories) { categoryRow($0) } }
                }
                if let usage = chat.usage { Section("Session") { usageRows(usage) } }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .task { await load() }
            .toolbar(content: doneItem)
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("Context")
        }
        .presentationDetents([.medium, .large])
    }

    @ToolbarContentBuilder private func doneItem() -> some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", action: { dismiss() })
        }
    }

    private func load() async {
        do {
            breakdown = try await chat.contextBreakdown()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func categoryRow(_ category: ContextCategory) -> some View {
        HStack {
            Circle().fill(Self.colour(of: category)).frame(square: 10)
            Text(category.label)
            Spacer()
            Text(category.tokens.formatted()).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    /// One labelled line per count. Optional counts only show when they are above zero.
    @ViewBuilder private func usageRows(_ usage: Usage) -> some View {
        let positive: (Int?) -> Int? = { ($0 ?? 0) > 0 ? $0 : nil }
        let lines: [(String, String)?] = [
            (String(localized: "Input tokens"), (usage.input ?? 0).formatted()),
            (String(localized: "Output tokens"), (usage.output ?? 0).formatted()),
            positive(usage.reasoning).map { (String(localized: "Reasoning tokens"), $0.formatted()) },
            (String(localized: "Model calls"), String(usage.calls ?? 0)),
            positive(usage.compressions).map { (String(localized: "Compressions"), String($0)) },
            usage.cacheHitPct.map { (String(localized: "Cache hit"), "\($0)%") },
            usage.costUsd.map { (String(localized: "Cost"), costText($0, estimated: usage.costStatus == "estimated")) },
        ]
        ForEach(lines.compactMap { $0 }, id: \.0) { LabeledContent($0.0, value: $0.1) }
    }

    private func costText(_ dollars: Double, estimated: Bool) -> String {
        let amount = String(format: "$%.4f", dollars)
        return estimated ? String(localized: "\(amount) (est.)", comment: "A cost that is only an estimate") : amount
    }

    private static func colour(of category: ContextCategory) -> Color {
        switch category.id {
        case "system", "system_prompt": .blue
        case "tools": .purple
        case "skills": .teal
        case "memory": .green
        case "mcp": .indigo
        case "conversation", "messages": .orange
        case "free": Color(.systemFill)
        default: .gray
        }
    }
}

/// The headline figure and a capsule bar, split in category-coloured pieces (never thinner than 2pt).
private struct BreakdownGauge: View {
    var breakdown: ContextBreakdown
    var tint: (ContextCategory) -> Color

    private var headline: String {
        let (used, limit) = (breakdown.contextUsed.formatted(), breakdown.contextMax.formatted())
        return String(localized: "\(used) of \(limit) tokens (\(breakdown.contextPercent)%)")
    }

    private var used: [ContextCategory] { breakdown.categories.filter { $0.tokens > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline).font(.headline)
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    HStack(spacing: 1) {
                        ForEach(used) { piece in
                            Rectangle().fill(tint(piece)).frame(width: width(of: piece, in: box.size.width))
                        }
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 10)
            if let model = breakdown.model { Text(model).quiet() }
        }
        .inset(v: 4)
    }

    private func width(of piece: ContextCategory, in total: CGFloat) -> CGFloat {
        let whole = CGFloat(max(1, breakdown.contextMax))
        return max(2, total * CGFloat(piece.tokens) / whole)
    }
}
