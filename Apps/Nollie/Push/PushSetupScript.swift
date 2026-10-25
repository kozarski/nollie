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
            "Apple push", "Gateway address", "Companion sign-in",
            "Put it on the gateway", "Start the companion", "Overview and test",
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
        .apple: "Turn on notifications, then \(DeviceWords.tap) Register.",
        .address: "Where the companion finds Hermes. Usually \(DeviceWords.this)'s address.",
        .signIn: "Its own sign-in, with the same account as the dashboard.",
    ]

    /// What the bot says above this card, given how far along things are.
    @MainActor
    func guideLine(setup: PushSetupModel, done: Bool, locked: Bool) -> String {
        if done {
            return self == .overview
                ? "That's it! \(DeviceWords.CompanionBrings) are all yours."
                : "That's done. \(DeviceWords.Tap) Continue."
        }
        if let line = Self.fixedLines[self] { return line }
        if self == .install {
            return setup.installedOnGateway
                ? "Installed. It restarts when the timer runs out, or \(DeviceWords.tap) Restart now."
                : "One \(DeviceWords.tap) puts everything on the gateway."
        }
        if self == .start {
            if setup.companionSignInRejected { return "The companion needs a new sign-in." }
            return locked ? "Hold on, the gateway is restarting…" : setup.startAdvice
        }
        return setup.companionHealthy
            ? "All set. Send a test to check it works from end to end."
            : "The companion isn't reporting in. Go back a step."
    }
}
