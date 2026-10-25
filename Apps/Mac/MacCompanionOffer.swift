import NollieCore
import SwiftUI

/// What asking the gateway about its Companion came to.
private enum CompanionAnswer {
    /// The gateway never answered, or the check failed. Worth asking again next launch.
    case unreachable
    /// It answered; the version is nil when no Companion is installed.
    case reached(version: String?)

    /// Waits up to ten seconds for the gateway to know its home folder, then asks. Asked too early
    /// the check finds nothing and invites an install onto a gateway that already has one (a restored
    /// gateway whose Companion was set up from the phone hit exactly that).
    @MainActor static func ask(_ model: AppModel, runtime: GatewayRuntime) async -> CompanionAnswer {
        var tries = 0
        while runtime.profileHome == nil && tries < 40 {
            try? await Task.sleep(for: .milliseconds(250))
            tries += 1
        }
        guard model.runtime === runtime, runtime.profileHome != nil else { return .unreachable }
        let check = PushSetupModel()
        await check.checkCompanion(runtime: runtime)
        return check.companionCheckError == nil ? .reached(version: check.installedVersion) : .unreachable
    }
}

/// Offers the Companion a single time, once the first gateway is up on this Mac, and owns the
/// sheets that follow the answer: gateway sign-in, the offer, and the install wizard.
///
/// The first-run tour, the lock and a sign-in owed by a restore may all be showing already. The
/// offer holds back for each of them and checks again whenever one goes away.
struct CompanionOffer: ViewModifier {
    /// True while the first-run tour is up.
    let touring: Bool

    @AppStorage("notificationsSetupCardDone") private var setupCardDone: Bool = false
    @AppStorage("companionPromptShown") private var alreadyAsked: Bool = false
    @Environment(AppModel.self) private var model

    private enum Sheet { case none, offer, wizard }

    /// Everything that decides whether this is a good moment, so one watcher covers them all.
    private struct Moment: Equatable {
        var gateway: UUID?
        var noSignInPrompt: Bool
        var noSignInOwed: Bool
        var unlocked: Bool
    }

    @State private var sheet = Sheet.none
    @State private var foundVersion: String?

    private var moment: Moment {
        Moment(gateway: model.runtime?.connection.id, noSignInPrompt: model.signInPrompt.isEmpty,
               noSignInOwed: model.needsSignIn == nil, unlocked: !model.lock.isLocked)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: moment, initial: true) { _, _ in considerOffering() }
            .sheet(isPresented: signInSheet) {
                GatewaySignInSheet(connections: model.signInPrompt).withAppModel()
            }
            .sheet(isPresented: flag(for: .offer)) { offerSheet.withAppModel() }
            .sheet(isPresented: flag(for: .wizard)) { wizardSheet.withAppModel() }
    }

    /// The sign-in sheet shares the window, so the lock and the other two sheets come first.
    private var signInSheet: Binding<Bool> {
        Binding(
            get: { !model.signInPrompt.isEmpty && !model.lock.isLocked && sheet == .none },
            set: { if !$0 { model.signInPrompt = [] } })
    }

    private func flag(for wanted: Sheet) -> Binding<Bool> {
        Binding(get: { sheet == wanted }, set: { if !$0 && sheet == wanted { sheet = .none } })
    }

    // MARK: Sheets

    private var offerSheet: some View {
        CompanionPromptSheet(
            found: foundVersion,
            authorization: model.push.authorization,
            install: { settle(.wizard, marksHandled: true) },
            allow: {
                settle(.none, marksHandled: true)
                Task { _ = await model.push.requestAuthorization() }
            },
            later: { settle(.none, marksHandled: false) })
    }

    private var wizardSheet: some View {
        NavigationStack {
            SetupWizardHost().toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = .none } }
            }
        }
        .frame(minWidth: 560, minHeight: 680)
    }

    /// Answers the offer. `marksHandled` records that the notification card needs no showing later.
    private func settle(_ next: Sheet, marksHandled: Bool) {
        setupCardDone = marksHandled
        sheet = next
    }

    // MARK: Timing

    private func considerOffering() {
        let clear = !touring && !model.isDemo && !alreadyAsked && model.signInPrompt.isEmpty
            && model.needsSignIn == nil && !model.lock.isLocked
        guard clear, let runtime = model.runtime else { return }
        alreadyAsked = true
        Task {
            switch await CompanionAnswer.ask(model, runtime: runtime) {
            case .unreachable:
                alreadyAsked = false
            case .reached(let version):
                foundVersion = version
                sheet = .offer
            }
        }
    }
}

extension View {
    func companionOffer(touring: Bool) -> some View {
        let offer = CompanionOffer(touring: touring)
        return self.modifier(offer)
    }
}
