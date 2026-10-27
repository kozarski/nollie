import SwiftUI
import NollieCore

/// "A computer of its own" on Bot settings' Computer tab: one switch on glass, then one plain
/// line for how its computer is, and steps only when something is needed. Its name, Start fresh,
/// Remove and the details wait on the tab's Advanced page (`HelperComputerAdvanced`).
struct HelperComputerSection: View {
    var profile: String
    var chat: ChatSession?
    /// Shared with the tab's title and its Advanced page, so they all read the same answer.
    var computer: HelperComputerModel
    @Environment(AppModel.self) private var model
    @State private var watching: ChatSession?
    @State private var watchNote: String?

    private var rt: GatewayRuntime? { model.runtime }
    private var name: String { rt?.profiles.first { $0.name == profile }?.shownName ?? profile }

    private var onMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private var run: HelperComputerSetupRun {
        #if os(macOS)
        CuaSetup.shared.run
        #else
        .unavailable
        #endif
    }

    private var working: Bool { rt.map { BotComputerActivity.usesOwnComputer(runtime: $0, profile: profile) } ?? false }

    private var screen: HelperComputerScreen {
        HelperComputerPresentation.screen(status: computer.status, error: computer.error, wantsOn: computer.wantsOn,
                                          onMac: onMac, run: run, working: working, name: name)
    }

    /// The chat whose live preview Watch opens: this one, else the helper's open chat.
    private var watchChat: ChatSession? { chat ?? rt?.chats.first { $0.profileName == profile } }

    var body: some View {
        VStack(spacing: 18) {
            GlassSwitch(.verbatim(HelperComputerPresentation.title),
                        isOn: Binding(get: { HelperComputerPresentation.switchIsOn(computer.status, wantsOn: computer.wantsOn) },
                                      set: { on in if let rt { Task { await computer.setSwitch(on, rt) } } }),
                        id: "profile.ownComputer")
                .disabled(toggleDisabled)
            content
            if computer.status?.exitNodeBlocksInternet == true { ExitNodeCard() }
            if let note = watchNote ?? computer.actionError.map(OwnComputerWords.plainProblem) {
                PageNote(.verbatim(note), symbol: "exclamationmark.triangle.fill", tint: .orange, id: "profile.ownComputer.note")
            }
        }
        .animation(.snappy, value: screen)
        .task(id: "\(rt?.connection.id.uuidString ?? "")/\(profile)") {
            guard let rt else { return }
            await computer.watchFromOnePage(rt)
        }
        #if os(macOS)
        .onChange(of: run) { _, now in
            guard now == .done, let rt else { return }
            Task {
                #if DEBUG
                if DemoMode.isOn { let _: JSONValue? = try? await rt.api.send("POST", "/api/_mock/own-computer", json: ["setup": "ready"]) }
                #endif
                await computer.load(rt)
            }
        }
        #endif
        .sheet(item: $watching) { chat in ComputerView(chat: chat).withAppModel() }
    }

    private var toggleDisabled: Bool {
        guard rt != nil, !computer.sending else { return true }
        switch screen {
        case .loading, .unavailable, .gettingReady, .settingUp: return true
        case .off(_, let busy): return busy
        default: return computer.status?.busy == true
        }
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .loading:
            ProgressView().spread(.center)
        case .unavailable(let text):
            PageNote(.verbatim(text))
        case .off(let hasComputer, let busy):
            if busy {
                waiting(computer.status?.state == .removing ? String(localized: "Removing its computer.") : String(localized: "Turning off its computer."),
                        id: "profile.ownComputer.busy")
            } else if hasComputer {
                PageNote("Its computer is kept, switched off, for next time.")
            } else {
                PageNote(.verbatim(HelperComputerPresentation.line))
            }
        case .setup(let prompt):
            steps(prompt)
        case .settingUp(let title, let fraction):
            VStack(spacing: 12) {
                Text(setupTitle(title)).font(.headline).foregroundStyle(Ink.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                PageNote("You can close this. Nollie keeps going.")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("profile.ownComputer.settingUp")
        case .gettingReady(let text):
            waiting(text, id: "profile.ownComputer.gettingReady")
        case .card(let word, let note):
            VStack(spacing: 18) {
                state(word)
                if let note { steps(note) }
                GlassButton("Watch", symbol: "eye", id: "profile.ownComputer.watch") { Task { await watch() } }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("profile.ownComputer.card")
        }
    }

    /// How its computer is, in one word and its colour.
    private func state(_ word: HelperComputerWord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: OwnComputerWords.symbol(word))
                .font(.title3.weight(.semibold))
                .foregroundStyle(OwnComputerWords.tint(word))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            Text(OwnComputerWords.word(word))
                .font(.title3.weight(.semibold))
                .foregroundStyle(OwnComputerWords.tint(word))
                .accessibilityIdentifier("profile.ownComputer.status")
        }
        .spread(.center)
    }

    /// Something under way: a spinner and what it is, in body text.
    private func waiting(_ text: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ProgressView()
            Text(text).font(.body).foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    /// The one thing to do next: a plain line and at most two capsules, one above the other.
    private func steps(_ prompt: HelperComputerPrompt) -> some View {
        VStack(spacing: 12) {
            PageNote(.verbatim(line(prompt)), id: "profile.ownComputer.prompt")
            if let action = prompt.action {
                Button { perform(action) } label: {
                    Text(OwnComputerWords.label(action)).font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity).inset(v: 6)
                }
                .buttonStyle(.nollieGlassProminent)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("profile.ownComputer.action." + action.rawValue)
            }
            if let action = prompt.secondary {
                Button { perform(action) } label: {
                    Text(OwnComputerWords.label(action)).font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity).inset(v: 6)
                }
                .buttonStyle(.nollieGlass)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("profile.ownComputer.action." + action.rawValue)
            }
        }
    }

    /// The step's line. Cua is named where it has to be got or updated; the rest is in plain
    /// words, and the add-on's own message only when it is plain too.
    private func line(_ prompt: HelperComputerPrompt) -> String {
        if prompt == HelperComputerPresentation.prompt(for: .cuaNotRunning, onMac: true) {
            return String(localized: "Your helpers' computers are paused on this Mac. Start them again to carry on.")
        }
        if prompt == HelperComputerPresentation.prompt(for: .cuaNotRunning, onMac: false) {
            return String(localized: "Your helpers' computers are paused on your Mac. Open Nollie on your Mac to start them again.")
        }
        if let message = computer.status?.message, prompt.line == message, prompt.action == nil {
            return OwnComputerWords.plainProblem(message)
        }
        return prompt.line
    }

    /// Where the Mac's setup has got to, without naming the tool.
    private func setupTitle(_ fallback: String) -> String {
        guard case .working(let step, _) = run else { return fallback }
        switch step {
        case .checking: return String(localized: "Checking your Mac")
        case .downloading: return String(localized: "Downloading what it needs")
        case .installing: return String(localized: "Installing what it needs")
        case .starting: return String(localized: "Starting up")
        case .preparing: return String(localized: "Getting ready to run computers")
        }
    }

    /// The live preview of this chat, or of the helper's main chat when opened from elsewhere.
    private func watch() async {
        if let watchChat { watching = watchChat; return }
        guard let rt, let stored = BotsHome.shared.entry(rt, profile).storedID,
              let chat = try? await rt.openChat(storedID: stored, title: nil, profile: profile) else {
            watchNote = String(localized: "Open a chat with \(name) once, then Watch.", comment: "Watch is a button's name")
            return
        }
        watching = chat
    }

    private func perform(_ action: HelperComputerAction) {
        switch action {
        case .notNow:
            computer.notNow()
        #if os(macOS)
        // Starting Cua goes through Nollie Runtime, which wakes Cua's background part only.
        case .setUp, .update, .finish, .tryAgain, .startCua:
            Task { await CuaSetup.shared.start() }
        case .quitCua:
            Task { await CuaSetup.shared.quitCuaThenUpdate() }
        case .getCua:
            CuaSetup.shared.openDownloadPage()
        #else
        case .setUp, .update, .finish, .tryAgain, .quitCua, .startCua, .getCua:
            break
        #endif
        }
    }
}

/// The Computer tab's Advanced page, for its own computer: what is true in a title, then its
/// name, Cua, the last problem word for word, Start fresh and Remove, each asking first.
struct HelperComputerAdvanced: View {
    var computer: HelperComputerModel
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false
    @State private var confirmRemove = false

    private var rt: GatewayRuntime? { model.runtime }
    private var name: String { rt?.profiles.first { $0.name == computer.profile }?.shownName ?? computer.profile }
    private var status: HelperComputerStatus? { computer.status }
    private var busy: Bool { computer.sending || status?.busy == true }

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 20) {
                if let status, status.on || status.hasComputer {
                    detail("Computer name", status.computerName ?? "nollie-\(computer.profile)", monospaced: true)
                        .accessibilityIdentifier("profile.ownComputer.info")
                }
                if let status {
                    detail("Cua", [OwnComputerWords.setup(status.setup), status.cuaVersion.map { String(localized: "Version \($0)") }]
                        .compactMap { $0 }.joined(separator: ", "))
                }
                if let problem { detail("Last problem", problem) }
            }
            GlassStack {
                if status?.on == true {
                    GlassButton("Start fresh", symbol: "arrow.counterclockwise", id: "profile.ownComputer.reset") { confirmReset = true }
                        .disabled(busy)
                }
                if let status, status.hasComputer, !status.on, !status.busy {
                    GlassButton("Remove its computer", symbol: "trash", role: .destructive, id: "profile.ownComputer.remove") { confirmRemove = true }
                        .disabled(busy)
                }
                GlassButton("Check again", symbol: "arrow.clockwise", id: "profile.ownComputer.check") {
                    guard let rt else { return }
                    Task {
                        #if os(macOS)
                        await CuaSetup.shared.refresh()
                        #endif
                        await computer.load(rt)
                    }
                }
                .disabled(rt == nil)
                #if os(macOS)
                GlassButton("Cua's website", symbol: "safari", id: "profile.ownComputer.cuaSite") { CuaSetup.shared.openDownloadPage() }
                #endif
            }
        }
        .task(id: "\(rt?.connection.id.uuidString ?? "")/\(computer.profile)") {
            guard let rt else { return }
            await computer.watchFromOnePage(rt)
        }
        .confirmationDialog("Erase \(name)'s computer and start fresh?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Erase and start fresh", role: .destructive) { if let rt { Task { await computer.reset(rt) } } }
        } message: { Text("Everything on it is erased, and it starts over.") }
        .confirmationDialog("Remove \(name)'s computer?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let rt { Task { await computer.remove(rt) } } }
        } message: { Text("Everything on it is erased. This can't be undone.") }
    }

    /// What went wrong last, word for word.
    private var problem: String? {
        if let error = computer.actionError { return error }
        if status?.state == .needsYou, let message = status?.message { return message }
        #if os(macOS)
        if case .failed(let reason) = CuaSetup.shared.run { return reason }
        #endif
        return computer.error
    }

    private func detail(_ title: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(Ink.text)
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .foregroundStyle(Ink.text2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .spread()
        .accessibilityElement(children: .combine)
    }
}

/// The top of the Computer tab's Advanced page for a bot with a computer of its own: how that
/// computer is, in a few words and its colour.
struct HelperComputerAdvancedHero: View {
    var computer: HelperComputerModel
    var name: String

    var body: some View {
        let shown = words
        PageHero(symbol: shown.0, title: .verbatim(shown.1), line: .verbatim(shown.2), tint: shown.3, id: "profile.computer.advanced.hero")
    }

    private var words: (String, String, String?, Color) {
        guard let status = computer.status else {
            return computer.error == nil ? ("ellipsis.circle", String(localized: "Checking"), nil, Ink.text2)
                                         : ("wifi.exclamationmark", String(localized: "Couldn't check \(name)'s computer"), nil, .orange)
        }
        switch status.state {
        case .gettingReady: return ("macwindow", String(localized: "\(name)'s computer is getting ready"), nil, .blue)
        case .turningOff: return ("macwindow", String(localized: "\(name)'s computer is turning off"), nil, Ink.text2)
        case .removing: return ("trash", String(localized: "\(name)'s computer is being removed"), nil, Ink.text2)
        default: break
        }
        if status.on {
            switch status.state {
            case .asleep:
                return ("moon.zzz.fill", String(localized: "\(name)'s computer is asleep"), String(localized: "It wakes when there's work."), Ink.text2)
            case .needsYou: return ("exclamationmark.triangle.fill", String(localized: "\(name)'s computer needs you"), nil, .orange)
            default: return ("checkmark.circle.fill", String(localized: "\(name)'s computer is ready"), nil, .green)
            }
        }
        return status.hasComputer
            ? ("macwindow", String(localized: "\(name)'s computer is switched off"), String(localized: "Kept for next time."), Ink.text2)
            : ("macwindow", String(localized: "No computer of its own"), nil, Ink.text2)
    }
}

/// Words, symbols and colours for its own computer, shared by the tab and its Advanced page.
enum OwnComputerWords {
    static func symbol(_ word: HelperComputerWord) -> String {
        switch word {
        case .ready: "checkmark.circle.fill"
        case .working: "hammer.fill"
        case .asleep: "moon.zzz.fill"
        case .needsYou: "exclamationmark.triangle.fill"
        }
    }

    static func tint(_ word: HelperComputerWord) -> Color {
        switch word {
        case .ready: .green
        case .working: .blue
        case .asleep: Ink.text2
        case .needsYou: .orange
        }
    }

    /// The status word on the computer's card, shown in the person's language.
    static func word(_ word: HelperComputerWord) -> String {
        switch word {
        case .ready: String(localized: "Ready", comment: "A computer's state")
        case .working: String(localized: "Working", comment: "A computer's state")
        case .asleep: String(localized: "Asleep", comment: "A computer's state")
        case .needsYou: String(localized: "Needs you", comment: "A computer's state")
        }
    }

    /// A step's button, without the tool's name.
    static func label(_ action: HelperComputerAction) -> String {
        switch action {
        case .setUp: String(localized: "Set it up for me")
        case .update: String(localized: "Update it")
        case .startCua: String(localized: "Start them again")
        case .finish: String(localized: "Finish setup")
        case .getCua: String(localized: "Download it")
        case .tryAgain: String(localized: "Try again")
        case .quitCua: String(localized: "Close it and update")
        case .notNow: String(localized: "Not now")
        }
    }

    /// What Cua needs, for the Advanced page.
    static func setup(_ setup: HelperComputerStatus.Setup) -> String {
        switch setup {
        case .ready: String(localized: "Ready", comment: "A computer's state")
        case .noCua: String(localized: "Not on your Mac")
        case .oldCua: String(localized: "Needs an update")
        case .cuaNotRunning: String(localized: "Not running")
        case .noRuntime: String(localized: "Needs one more piece")
        }
    }

    /// The add-on's sentence when it is plain; otherwise plain words, and the sentence itself
    /// waits on the Advanced page.
    static func plainProblem(_ text: String) -> String {
        let technical = ["Cua", "MCP", "API", "gateway", "Gateway", "token", "HTTP", "Traceback", "{", "lume", "Lume"]
        guard technical.contains(where: text.contains) else { return text }
        if text.hasPrefix("Cua didn't answer") { return String(localized: "Its computer didn't answer just now. Nollie keeps checking.") }
        return String(localized: "Something went wrong with its computer. Advanced has the details.", comment: "Advanced is the name of a page")
    }
}

/// The models whose watch is running, so the tab and its Advanced page never read twice at once.
@MainActor private enum OwnComputerWatch {
    static var running: Set<ObjectIdentifier> = []
}

extension HelperComputerModel {
    /// Reads while a page about it is open, one loop at a time: a page opened over another takes
    /// the watch over once the one under it stops.
    func watchFromOnePage(_ rt: GatewayRuntime) async {
        let key = ObjectIdentifier(self)
        while !Task.isCancelled {
            if !OwnComputerWatch.running.contains(key) {
                OwnComputerWatch.running.insert(key)
                #if os(macOS)
                await CuaSetup.shared.refresh()
                #endif
                await watch(rt) {
                    #if os(macOS)
                    CuaSetup.shared.isWorking
                    #else
                    false
                    #endif
                }
                OwnComputerWatch.running.remove(key)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
