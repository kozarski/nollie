import SwiftUI

enum FirstTaskIdea: String, CaseIterable, Identifiable {
    case day, purchase, weekend

    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: "Plan my day"
        case .purchase: "Compare a purchase"
        case .weekend: "Find weekend plans"
        }
    }
    var symbol: String {
        switch self {
        case .day: "sun.max"
        case .purchase: "tag"
        case .weekend: "sparkles"
        }
    }
    var message: String {
        switch self {
        case .day: "Can you help me plan my day?"
        case .purchase: "Can you help me find a better price?"
        case .weekend: "Can you help me find something fun to do this weekend?"
        }
    }
}

/// Choosing an idea prepares a message. The composer remains the only send action.
struct FirstTaskIdeas: View {
    var onChoose: (String) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("A small place to start")
                .font(.title3.weight(.semibold))
            ForEach(FirstTaskIdea.allCases) { idea in
                Button { onChoose(idea.message) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: idea.symbol)
                            .font(.title3).foregroundStyle(Color.accentColor)
                            .frame(width: 28)
                        Text(idea.title).font(.body.weight(.medium))
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .inset(h: 18, v: 16)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 20))
                    .contentShape(.rect(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("firstTask.\(idea.id)")
            }
        }
        .frame(maxWidth: 410)
    }
}
