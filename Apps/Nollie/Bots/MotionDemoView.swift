import SwiftUI
import NollieCore

/// Every state the characters know, side by side, each on one of the looks. Reached from
/// Settings, Bots, Preview motion, and from the DEBUG `-nollie-motion-demo` flag.
struct MotionDemoView: View {
    /// On: each figure holds its own state. Off: all of them settle to idle.
    @State private var holds = true
    @State private var hopping = false

    /// The states in order, each handed the next look in turn, starting over when looks run out.
    private let lineup: [(state: CharacterState, look: CharacterLookID)] = {
        let looks = Array(CharacterLookID.allCases)
        return CharacterState.allCases.enumerated().map { ($1, looks[$0 % looks.count]) }
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 18) {
                    ForEach(lineup, id: \.state.rawValue) { entry in
                        figure(entry.state, entry.look)
                    }
                }
                .padding(16)
                buttons
            }
        }
        .background(Color(.systemBackground))
        .inlineTitle("Preview motion")
    }

    private func figure(_ state: CharacterState, _ look: CharacterLookID) -> some View {
        VStack(spacing: 6) {
            CharacterView(
                look: look, state: shown(for: state), size: 72,
                seed: CharacterLookID.seed("demo-" + state.rawValue))
            Text(state.caption).small(.caption2).lineLimit(1)
        }
    }

    /// Hopping sends everyone to "done".
    private func shown(for state: CharacterState) -> CharacterState {
        if hopping { return .done }
        return holds ? state : .idle
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button(holds ? "Release states" : "Hold states") { holds.toggle() }
            Button("Happy hop (all)") { Task { await hop() } }
                .disabled(hopping)
        }
        .buttonStyle(.nollieGlass)
        .padding(.bottom, 120)
    }

    private func hop() async {
        hopping = true
        defer { hopping = false }
        try? await Task.sleep(for: .seconds(CharacterCatalog.shared.state(.done).oneShot ?? 1.6))
    }
}
