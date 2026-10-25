import SwiftUI
import NollieCore

/// Model: where the bot thinks, then the plain choices in order: on this Mac first (recommended),
/// then a plan people already pay for. An API key and every model by name are under Advanced.
struct ProfileModelTab: View {
    var state: ProfileCardState

    var body: some View {
        let stance = state.thinks.stance
        PageHero(symbol: stance.symbol, title: stance.title, line: stance.line, tint: stance.tint, id: "profile.model.hero")
        if let options = state.options {
            choices(options.providers)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 60)
        }
        AdvancedLink(id: "profile.model.advanced") { ModelAdvanced(state: state) }
    }

    @ViewBuilder private func choices(_ providers: [ModelProvider]) -> some View {
        let hasModels = { (p: ModelProvider) in !(p.models ?? []).isEmpty }
        let local = providers.filter { ModelNames.isLocal($0.slug) && hasModels($0) }
        let plans = providers.filter { ModelNames.isPlan($0.slug) && $0.authenticated != false && hasModels($0) }
        let thinks = state.thinks
        GlassStack {
            Choice(state: state, title: CardThinks.macWords, symbol: "desktopcomputer", providers: local,
                   chosen: thinks == .mac, idle: local.isEmpty ? "Not set up" : "Recommended", id: "profile.model.mac")
            Choice(state: state, title: "ChatGPT or Claude plan", symbol: "person.crop.circle.badge.checkmark", providers: plans,
                   chosen: thinks.isPlan, idle: plans.isEmpty ? "Not signed in" : nil, id: "profile.model.plan")
        }
        if local.isEmpty && thinks != .mac {
            PageNote("Private and free once a model is on your Mac. Get one in Settings, under Connection.", symbol: "sparkles")
        }
    }
}

/// One plain choice on a glass capsule; its menu lists the models it offers.
private struct Choice: View {
    var state: ProfileCardState
    var title: String
    var symbol: String
    var providers: [ModelProvider]
    var chosen: Bool
    var idle: String?
    var id: String

    var body: some View {
        let face = CardChoiceLabel(title: title, symbol: chosen ? "checkmark.circle.fill" : symbol,
                                   tint: chosen ? .green : Ink.text2, value: chosen ? state.shortModel : idle,
                                   menu: !providers.isEmpty)
        if providers.isEmpty {
            face.accessibilityIdentifier(id)
        } else {
            Menu {
                ForEach(providers) { provider in
                    Section(Papertrail.providerLabel(provider.slug) ?? provider.name) {
                        ForEach(ModelNames.offered(provider), id: \.self) { model in
                            Button(model) { Task { await state.saveModel(provider: provider.slug, model: model) } }
                        }
                    }
                }
            } label: { face }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityIdentifier(id)
        }
    }
}
