import NollieCore
import SwiftUI

/// The phone's three motion settings, kept in storage. A Mac has no gyroscope, so no tilt.
#if os(iOS)
@MainActor
private struct MotionPrefs: DynamicProperty {
    @AppStorage(BotMotionSource.enabledKey) var moving = true
    @AppStorage(BotMotionSource.tiltKey) var tilting = false
    @AppStorage(BotMotionSource.styleKey) var style = "lively"
}
#endif

/// Settings › Bots: the bot that answers first, large, then your bots, which one opens first, and
/// whether they move. How they move waits behind Advanced.
struct BotsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var addingBot = false
    @AppStorage(GatewayRuntime.defaultProfileKey) private var chosenFirst = ""
    #if os(iOS)
    private var motion = MotionPrefs()
    #else
    @AppStorage(BotAmbient.animateKey) private var animating = true
    #endif

    /// The choice that leaves it to the bot your Mac has active.
    private static var leaveToMac: String {
        #if os(macOS)
        String(localized: "Automatic", comment: "Which bot opens first: left to the Mac")
        #else
        String(localized: "Same as your Mac", comment: "Which bot opens first: left to the Mac")
        #endif
    }

    var body: some View {
        SettingsPage("settings.bots.page") {
            if let runtime = model.runtime {
                BotsHeadline(profiles: runtime.profiles, chosen: chosenFirst)
                botRows(runtime.profiles)
                if !runtime.profiles.isEmpty { firstChoice(runtime) }
            } else {
                PageHero(symbol: "person.2.slash", title: "No bots yet", line: "Set up Nollie in Connection to meet them.",
                         tint: Ink.text2, id: "settings.bots.hero")
            }
            movementSwitch
            AdvancedLink(id: "settings.bots.advanced") { BotsAdvancedPage().untitledPage() }
        }
        .untitledPage()
        .sheet(isPresented: $addingBot) {
            if let runtime = model.runtime { NewBotSheet(runtime: runtime).sheetFrame().withAppModel() }
        }
    }

    private func botRows(_ profiles: [ProfileInfo]) -> some View {
        GlassStack {
            ForEach(profiles) { bot in
                NavigationLink {
                    ProfileCardView(profileName: bot.name, initialTab: .look)
                } label: {
                    BotRowLabel(profile: bot.name, name: bot.shownName)
                }
                .buttonStyle(.plain)
                .testID("settings.bots.profile." + bot.name)
            }
            GlassButton("New bot", symbol: "plus", id: "settings.bots.new") { addingBot = true }
        }
    }

    private func firstChoice(_ runtime: GatewayRuntime) -> some View {
        let options = [("", Self.leaveToMac)] + runtime.profiles.map { ($0.name, $0.shownName) }
        return GlassChoice("Opens first", selection: $chosenFirst, options: options, id: "settings.bots.default")
            .onChange(of: chosenFirst) { runtime.returnToDefaultProfile() }
    }

    @ViewBuilder private var movementSwitch: some View {
        #if os(iOS)
        GlassSwitch("Motion", isOn: motion.$moving, id: "settings.bots.motion")
            .onChange(of: motion.moving) { BotMotionSource.shared.apply() }
        #else
        GlassSwitch("Animate bots", isOn: $animating, id: "settings.bots.animate")
        #endif
    }
}

/// What is true now: a moment while the bots load, then the one that answers first, with how
/// many there are.
private struct BotsHeadline: View {
    var profiles: [ProfileInfo]
    var chosen: String

    /// Bot the app returns to: the one picked here, otherwise the Mac's own default, otherwise the first.
    private var answersFirst: ProfileInfo? {
        profiles.first { $0.name == chosen } ?? profiles.first { $0.isDefault == true } ?? profiles.first
    }

    var body: some View {
        if let bot = answersFirst {
            BotsHero(profile: bot.name, title: String(localized: "\(profiles.count) bots"),
                     line: String(localized: "\(bot.shownName) answers first."))
        } else {
            PageHero(symbol: "person.2", title: "Finding your bots", tint: Ink.text2, id: "settings.bots.hero")
        }
    }
}

/// The top of Bots: the bot that answers first in place of a symbol, and the count. The face
/// carries the bot's colour; the words stay in ink, since some bot colours are too light to read.
private struct BotsHero: View {
    var profile: String
    var title: String
    var line: String

    var body: some View {
        VStack(spacing: 12) {
            BotAvatar(profile: profile, size: 96).frame(height: 104)
            Text(title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Ink.text)
                .accessibilityAddTraits(.isHeader)
                .testID("settings.bots.hero")
            Text(line)
                .font(.title3)
                .foregroundStyle(Ink.text2)
                .testID("settings.bots.lead")
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
    }
}

/// One bot on a glass capsule: its face and its name. VoiceOver reads the name.
private struct BotRowLabel: View {
    var profile: String
    var name: String

    var body: some View {
        HStack(spacing: 14) {
            BotAvatar(profile: profile, size: 34)
            Text(name).font(.headline).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Ink.text3)
                .accessibilityHidden(true)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 22))
        .frame(minHeight: 54)
        .contentShape(Capsule())
        .nollieGlass(.regular, in: Capsule(), solid: Ink.card)
        .accessibilityElement(children: .combine)
    }
}

/// Bots › Advanced: how the bots move, leaning with the phone, and every move to watch.
private struct BotsAdvancedPage: View {
    #if os(iOS)
    private var motion = MotionPrefs()
    private static let styles = [("lively", String(localized: "Lively", comment: "How bots move")),
                                  ("calm", String(localized: "Calm", comment: "How bots move")),
                                  ("still", String(localized: "Still", comment: "How bots move: not at all"))]
    #endif

    var body: some View {
        SettingsPage("settings.bots.advanced.page") {
            PageHero(symbol: "figure.walk.motion", title: "How bots move", tint: Ink.text2, id: "settings.bots.advanced.hero")
            #if os(iOS)
            // Motion and tilt rely on the phone's gyroscope, which a Mac lacks.
            GlassStack {
                GlassChoice("Style", selection: motion.$style, options: Self.styles, id: "settings.bots.style")
                GlassSwitch("Tilt with \(DeviceWords.your)", isOn: motion.$tilting, id: "settings.bots.tilt")
                    .disabled(!motion.moving)
                    .onChange(of: motion.tilting) { BotMotionSource.shared.apply() }
            }
            if !motion.moving { PageNote("Tilt needs Motion on.", id: "settings.bots.motionOff") }
            #endif
            GlassLink("Preview motion", symbol: "play.circle", id: "settings.bots.preview") { MotionDemoView() }
        }
    }
}
