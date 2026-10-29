import SwiftUI
import NollieCore

extension PushSetupView {
    /// The six cards of the setup, in order.
    enum SetupStep: Int, CaseIterable, Identifiable {
        case apple
        case address
        case signIn
        case install
        case start
        case overview

        var id: Int { self.rawValue }
        var next: SetupStep? { Self(rawValue: rawValue + 1) }
        var previous: SetupStep? { Self(rawValue: rawValue - 1) }

        private static let headings = [
            String(localized: "Apple push"), String(localized: "Gateway address"), String(localized: "Companion sign-in"),
            String(localized: "Put it on the gateway"), String(localized: "Start the companion"), String(localized: "Overview and test"),
        ]

        var title: String { Self.headings[rawValue] }
    }
}

extension PushSetupView.SetupStep {
    /// Whether this card has everything it asks for.
    @MainActor
    func isComplete(setup: PushSetupModel, push: PushRegistrar, runtime: GatewayRuntime) -> Bool {
        let healthy = setup.companionHealthy
        let installed = setup.installedOnGateway || setup.alreadyServing
        var signedIn = true
        if case .needsSignIn = setup.credential(for: runtime) { signedIn = setup.alreadyServing }
        let table: [Self: Bool] = [
            .apple: setup.appleReady(push: push),
            .address: setup.addressValid,
            .signIn: signedIn,
            .install: installed && !setup.restartPending,
            .start: healthy,
            .overview: healthy && setup.testPassed,
        ]
        return table[self] ?? false
    }

    /// What the bot says above the cards that never change their tune.
    private static let fixedLines: [Self: String] = [
        .apple: String(localized: "Turn on notifications, then \(DeviceWords.tap) Register.", comment: "%@ is tap or click"),
        .address: String(localized: "Where the companion finds Hermes. Usually \(DeviceWords.this)'s address.",
                         comment: "%@ is this iPhone, this iPad or this Mac"),
        .signIn: String(localized: "Its own sign-in, with the same account as the dashboard."),
    ]

    /// What the bot says above this card, given how far along things are.
    @MainActor
    func guideLine(setup: PushSetupModel, done: Bool, locked: Bool) -> String {
        if done {
            return self == .overview
                ? String(localized: "That's it! \(DeviceWords.CompanionBrings) are all yours.", comment: "%@ is Notifications and approvals")
                : String(localized: "That's done. \(DeviceWords.Tap) Continue.", comment: "%@ is Tap or Click")
        }
        if let line = Self.fixedLines[self] { return line }
        if self == .install {
            return setup.installedOnGateway
                ? String(localized: "Installed. It restarts when the timer runs out, or \(DeviceWords.tap) Restart now.", comment: "%@ is tap or click")
                : String(localized: "One \(DeviceWords.tap) puts everything on the gateway.", comment: "%@ is tap or click, as a noun")
        }
        if self == .start {
            if setup.companionSignInRejected { return String(localized: "The companion needs a new sign-in.") }
            return locked ? String(localized: "Hold on, the gateway is restarting…") : setup.startAdvice
        }
        return setup.companionHealthy
            ? String(localized: "All set. Send a test to check it works from end to end.")
            : String(localized: "The companion isn't reporting in. Go back a step.")
    }
}
