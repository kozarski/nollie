import SwiftUI
import NollieCore

/// Settings › Appearance: the look now in one symbol and the accent, then the theme, the accent,
/// Liquid Glass and chat summaries. Glass strength, text and every chat option wait behind Advanced.
struct AppearanceView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("colorSchemePreference") private var scheme = "system"
    @AppStorage(AppTheme.accentKey) private var accentID = "blue"
    @AppStorage(GlassAppearance.enabledKey) private var glassEnabled = GlassAppearance.defaultEnabled
    @AppStorage(ChatSummarizer.titlesKey) private var summaryTitles = ChatSummarizer.titlesOn
    @AppStorage(ChatSummarizer.previewsKey) private var summaryPreviews = ChatSummarizer.previewsOn

    /// Accessibility settings keep every surface solid, whatever the switch says.
    private var forcedSolid: Bool { reduceTransparency || contrast == .increased }

    private var heroSymbol: String {
        switch scheme {
        case "light": "sun.max.fill"
        case "dark": "moon.fill"
        default: "circle.lefthalf.filled"
        }
    }

    private var heroTitle: String {
        switch scheme {
        case "light": String(localized: "Light", comment: "The light theme")
        case "dark": String(localized: "Dark", comment: "The dark theme")
        default: String(localized: "Matches \(DeviceWords.your)", comment: "The theme follows the device; the device is 'your Mac' or 'your iPhone'")
        }
    }

    private var heroLine: String {
        if forcedSolid { return String(localized: "Kept solid for your accessibility settings.") }
        return glassEnabled ? String(localized: "Liquid Glass on.") : String(localized: "Solid look.")
    }

    /// A word beside Chat summaries: on or off, when this device can write them at all.
    private var summariesWord: String? {
        guard ChatSummarizer.isAvailable else { return nil }
        return summaryTitles || summaryPreviews
            ? String(localized: "On", comment: "A switch state") : String(localized: "Off", comment: "A switch state")
    }

    var body: some View {
        SettingsPage("appearance.page") {
            PageHero(symbol: heroSymbol, title: .verbatim(heroTitle), line: .verbatim(heroLine),
                     tint: AppTheme.accent(accentID).color, id: "appearance.hero")
            GlassStack {
                GlassChoice("Theme", selection: $scheme,
                            options: [("system", String(localized: "System", comment: "Theme follows the system")),
                                      ("light", String(localized: "Light", comment: "The light theme")),
                                      ("dark", String(localized: "Dark", comment: "The dark theme"))],
                            id: "appearance.theme")
                GlassSwitch("Liquid Glass", isOn: $glassEnabled, id: "appearance.glass.enabled")
            }
            AccentSwatches(accentID: $accentID)
            GlassLink("Chat summaries", symbol: "sparkles", value: summariesWord, id: "appearance.summaries") {
                SummariesSettingsView().untitledPage()
            }
            AdvancedLink(id: "appearance.advanced") { AppearanceAdvancedPage().untitledPage() }
        }
    }
}

/// The accents as one row of large swatches, the chosen one ringed. Two rows of four where one
/// row doesn't fit. VoiceOver reads each by name.
private struct AccentSwatches: View {
    @Binding var accentID: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { swatches(AppTheme.accents) }
            VStack(spacing: 16) {
                HStack(spacing: 22) { swatches(Array(AppTheme.accents.prefix(4))) }
                HStack(spacing: 22) { swatches(Array(AppTheme.accents.dropFirst(4))) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accent colour")
        .testID("appearance.accent")
    }

    private func swatches(_ accents: [AppTheme.Accent]) -> some View {
        ForEach(accents) { a in
            let chosen = accentID == a.id
            Button { withAnimation(.snappy) { accentID = a.id } } label: {
                Circle().fill(a.color)
                    .frame(width: 44, height: 44)
                    .overlay {
                        if chosen { Image(systemName: "checkmark").foregroundStyle(.white).font(.body.weight(.bold)) }
                    }
                    .background {
                        Circle().strokeBorder(chosen ? a.color.opacity(0.5) : .clear, lineWidth: 3).padding(-5)
                    }
                    .padding(5)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(chosen ? .isSelected : [])
            .accessibilityLabel(a.name)
            .testID("appearance.accent." + a.id)
        }
    }
}

/// Appearance › Advanced: how much glass, text size and bubbles, the rest of the chat options,
/// and starting over. The top says how strong the glass is and how chats look.
private struct AppearanceAdvancedPage: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("colorSchemePreference") private var scheme = "system"
    @AppStorage(AppTheme.accentKey) private var accentID = "blue"
    @AppStorage(GlassAppearance.enabledKey) private var glassEnabled = GlassAppearance.defaultEnabled
    @AppStorage(GlassAppearance.strengthKey) private var glassStrength = GlassAppearance.defaultStrength
    @AppStorage(ChatStyle.showToolCalls) private var showToolCalls = true
    @AppStorage(ChatStyle.showReasoning) private var showReasoning = true
    @AppStorage(ChatStyle.showTurnStats) private var showTurnStats = false
    @AppStorage(ChatStyle.showSystemNotes) private var showSystemNotes = true
    @AppStorage(ChatStyle.timeReveal) private var timeReveal = true
    @AppStorage(ChatStyle.collapseAfterTurn) private var collapseAfterTurn = false
    @AppStorage(ChatStyle.showToolOutput) private var showToolOutput = true
    @AppStorage(ChatStyle.compactTools) private var compactTools = false
    @AppStorage(ChatStyle.currentStepOnly) private var currentStepOnly = false
    @AppStorage(ChatStyle.groupSteps) private var groupSteps = true
    @AppStorage(ChatStyle.wideReplies) private var wideReplies = false
    @AppStorage(ChatStyle.bubbleStyle) private var bubbleStyle = "rounded"
    @AppStorage(ChatStyle.botTint) private var botTint = false
    @AppStorage(ChatStyle.userBubble) private var userBubble = "ink"
    @AppStorage(ChatStyle.textSize) private var textSize = "default"
    @AppStorage(ChatStyle.returnSends) private var returnSends = false
    @AppStorage(ChatStyle.headerShowsTitle) private var headerShowsTitle = false
    @State private var listCleared = false
    @State private var confirmReset = false

    private var forcedSolid: Bool { reduceTransparency || contrast == .increased }
    private var strength: Double { GlassAppearance.normalizedStrength(glassStrength) }

    /// The glass now: its strength, or why it is solid.
    private var heroTitle: String {
        if forcedSolid { return String(localized: "Kept solid") }
        guard glassEnabled else { return String(localized: "Solid look") }
        return String(localized: "Glass at \(strength.formatted(.percent.precision(.fractionLength(0))))",
                      comment: "How strong the glass is, as a percentage")
    }

    /// How chats look, in a few words: "Default text, rounded bubbles."
    private var heroLine: String {
        switch (textSize, bubbleStyle) {
        case ("small", "tailed"): String(localized: "Small text, tailed bubbles.")
        case ("small", "plain"): String(localized: "Small text, plain bubbles.")
        case ("small", _): String(localized: "Small text, rounded bubbles.")
        case ("large", "tailed"): String(localized: "Large text, tailed bubbles.")
        case ("large", "plain"): String(localized: "Large text, plain bubbles.")
        case ("large", _): String(localized: "Large text, rounded bubbles.")
        case (_, "tailed"): String(localized: "Default text, tailed bubbles.")
        case (_, "plain"): String(localized: "Default text, plain bubbles.")
        default: String(localized: "Default text, rounded bubbles.")
        }
    }

    var body: some View {
        SettingsPage("appearance.advanced.page") {
            PageHero(symbol: glassEnabled && !forcedSolid ? "drop.halffull" : "circle.fill", title: .verbatim(heroTitle), line: .verbatim(heroLine),
                     tint: glassEnabled && !forcedSolid ? AppTheme.accent(accentID).color : Ink.text2,
                     id: "appearance.advanced.hero")
            VStack(spacing: 14) {
                PageHeading("Glass strength")
                strengthSlider
                    .disabled(!glassEnabled || forcedSolid)
                if forcedSolid {
                    PageNote("Your accessibility settings keep these surfaces solid.", symbol: "accessibility")
                } else if !glassEnabled {
                    PageNote("Turn on Liquid Glass to choose this.")
                }
            }
            GlassStack {
                GlassChoice("Text size", selection: $textSize,
                            options: [("small", String(localized: "Small", comment: "A text size")),
                                      ("default", String(localized: "Default", comment: "A text size")),
                                      ("large", String(localized: "Large", comment: "A text size"))],
                            id: "appearance.textSize")
                GlassChoice("Bubbles", selection: $bubbleStyle,
                            options: [("rounded", String(localized: "Rounded", comment: "A chat bubble shape")),
                                      ("tailed", String(localized: "Tailed", comment: "A chat bubble shape")),
                                      ("plain", String(localized: "Plain", comment: "A chat bubble shape"))],
                            id: "appearance.bubbles")
                GlassLink("More chat options", symbol: "bubble.left.and.text.bubble.right", id: "appearance.chatOptions") {
                    ChatOptionsPage().untitledPage()
                }
            }
            VStack(spacing: 14) {
                GlassButton("Clear the saved chat list", symbol: "arrow.clockwise", value: listCleared ? String(localized: "Cleared", comment: "The saved chat list was cleared") : nil,
                            id: "appearance.clearList") {
                    SessionCache.clearAll()
                    listCleared = true
                }
                PageNote("Your chats stay. They load again next time.")
            }
            GlassButton("Start over", symbol: "arrow.counterclockwise", role: .destructive, id: "appearance.reset") {
                confirmReset = true
            }
        }
        .confirmationDialog(
            "Put every look back as it came?", isPresented: $confirmReset, titleVisibility: .visible,
            actions: {
                Button("Start over", role: .destructive, action: resetAppearance)
                Button("Cancel", role: .cancel) {}
            },
            message: { Text("Your accent and chat summaries stay as they are.") })
    }

    /// From more solid to more glass, on a capsule. When the words leave the slider too little
    /// room (large text, a narrow screen), they go under it.
    private var strengthSlider: some View {
        let slider = Slider(value: Binding(get: { strength }, set: { glassStrength = $0 }), in: 0...1, step: 0.05)
            .accessibilityLabel("Glass strength")
            .accessibilityValue(Text(strength, format: .percent.precision(.fractionLength(0))))
            .testID("appearance.glass.strength")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                Text("More solid").fixedSize().accessibilityHidden(true)
                slider.frame(minWidth: 140)
                Text("More glass").fixedSize().accessibilityHidden(true)
            }
            VStack(spacing: 8) {
                slider
                HStack {
                    Text("More solid")
                    Spacer(minLength: 8)
                    Text("More glass").multilineTextAlignment(.trailing)
                }
                .accessibilityHidden(true)
            }
        }
        .font(.body)
        .foregroundStyle(Ink.text)
        .inset(h: 22, v: 14)
        .frame(minHeight: 54)
        .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
    }

    private func resetAppearance() {
        scheme = "system"
        glassEnabled = GlassAppearance.defaultEnabled
        glassStrength = GlassAppearance.defaultStrength
        showToolCalls = true
        showReasoning = true
        showTurnStats = false
        showSystemNotes = true
        timeReveal = true
        collapseAfterTurn = false
        showToolOutput = true
        compactTools = false
        currentStepOnly = false
        groupSteps = true
        wideReplies = false
        textSize = "default"
        bubbleStyle = "rounded"
        userBubble = "ink"
        botTint = false
        returnSends = false
        headerShowsTitle = false
    }
}

/// Appearance › Advanced › More chat options: how your chats look, and what shows while a bot works.
private struct ChatOptionsPage: View {
    @AppStorage(ChatStyle.showToolCalls) private var showToolCalls = true
    @AppStorage(ChatStyle.showReasoning) private var showReasoning = true
    @AppStorage(ChatStyle.showTurnStats) private var showTurnStats = false
    @AppStorage(ChatStyle.showSystemNotes) private var showSystemNotes = true
    @AppStorage(ChatStyle.timeReveal) private var timeReveal = true
    @AppStorage(ChatStyle.collapseAfterTurn) private var collapseAfterTurn = false
    @AppStorage(ChatStyle.showToolOutput) private var showToolOutput = true
    @AppStorage(ChatStyle.compactTools) private var compactTools = false
    @AppStorage(ChatStyle.currentStepOnly) private var currentStepOnly = false
    @AppStorage(ChatStyle.groupSteps) private var groupSteps = true
    @AppStorage(ChatStyle.wideReplies) private var wideReplies = false
    @AppStorage(ChatStyle.botTint) private var botTint = false
    @AppStorage(ChatStyle.userBubble) private var userBubble = "ink"
    @AppStorage(ChatStyle.returnSends) private var returnSends = false
    @AppStorage(ChatStyle.headerShowsTitle) private var headerShowsTitle = false

    var body: some View {
        SettingsPage("appearance.chatOptions.page") {
            PageHero(symbol: "bubble.left.and.text.bubble.right.fill", title: "Chat options", tint: Ink.text2,
                     id: "appearance.chatOptions.hero")
            VStack(spacing: 14) {
                PageHeading("Your chats")
                GlassStack {
                    GlassChoice("Your messages", selection: $userBubble,
                                options: [("ink", String(localized: "Ink", comment: "Your message bubbles in the plain ink colour")),
                                          ("accent", String(localized: "Accent colour"))], id: "appearance.userBubble")
                    GlassSwitch("Bot colour on replies", isOn: $botTint, id: "appearance.botTint")
                    GlassSwitch("Wide replies", isOn: $wideReplies, id: "appearance.wideReplies")
                    #if os(iOS)
                    GlassChoice("Chat header shows", selection: $headerShowsTitle,
                                options: [(false, String(localized: "Bot name")), (true, String(localized: "Chat title"))],
                                id: "appearance.header")
                    GlassSwitch("Pull left for times", isOn: $timeReveal, id: "appearance.timeReveal")
                    GlassSwitch("Return key sends", isOn: $returnSends, id: "appearance.returnSends")
                    #endif
                }
            }
            VStack(spacing: 14) {
                PageHeading("While a bot works")
                GlassStack {
                    GlassSwitch("Steps it takes", isOn: $showToolCalls, id: "appearance.toolCalls")
                    GlassSwitch("Its thinking", isOn: $showReasoning, id: "appearance.reasoning")
                    GlassSwitch("Reply speed", isOn: $showTurnStats, id: "appearance.turnStats")
                    GlassSwitch("Notes from Nollie", isOn: $showSystemNotes, id: "appearance.systemNotes")
                    GlassSwitch("Fold each turn's steps", isOn: $groupSteps, id: "appearance.groupSteps")
                    GlassSwitch("Fold finished steps", isOn: $collapseAfterTurn, id: "appearance.collapseAfterTurn")
                    GlassSwitch("What each step found", isOn: $showToolOutput, id: "appearance.toolOutput")
                    GlassSwitch("Smaller step cards", isOn: $compactTools, id: "appearance.compactTools")
                    GlassSwitch("Only the current step", isOn: $currentStepOnly, id: "appearance.currentStepOnly")
                }
                PageNote("Hidden steps stay in your history. Approval requests always appear.")
            }
        }
    }
}
