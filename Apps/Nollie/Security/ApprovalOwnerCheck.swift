import Foundation
import NollieCore

/// Face ID for buying and sending: before a yes to an Ask first approval that pays, sends or posts
/// goes out, the device checks it's the owner (Face ID, Touch ID, the passcode or the Mac's
/// password). Every way of saying yes goes through `ChatSession.respond`, which asks this first:
/// the card, a notification, the menu bar, /approve and Siri. Deny never asks.
@MainActor
enum ApprovalOwnerCheck {
    /// Settings › Privacy. On unless the person turned it off, for new installs and upgrades alike.
    nonisolated static let key = "approvals.ownerCheck"

    nonisolated static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        // `bool(forKey:)` also reads "NO" from a launch argument or a managed setting.
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    /// Whether a yes to this approval will ask, so the card can show a lock on its button.
    static func willAsk(_ approval: ApprovalRequest?, on: Bool = isOn(),
                        authenticator: any DeviceOwnerAuthenticating = RememberedSignInCoordinator.defaultAuthenticator()) -> Bool {
        on && AskFirstAsk.needsOwner(approval) && authenticator.canAuthenticate
    }

    /// Requests being checked right now. A second tap while Face ID is up asks nothing more.
    private static var checking: Set<String> = []

    /// True when the yes may go out. False for a failed or cancelled check, or one already showing.
    /// A device with no passcode at all has nothing to check with, so it answers as before.
    static func check(_ approval: ApprovalRequest, bot: String, on: Bool = isOn(),
                      authenticator: any DeviceOwnerAuthenticating = RememberedSignInCoordinator.defaultAuthenticator()) async -> Bool {
        guard on, AskFirstAsk.needsOwner(approval), authenticator.canAuthenticate else { return true }
        let key = approval.requestId
        guard !checking.contains(key) else { return false }
        checking.insert(key)
        defer { checking.remove(key) }
        return await authenticator.authenticate(reason: reason(approval, bot: bot)) != nil
    }

    /// What the system shows beside the check, such as "Let Scout pay for something".
    static func reason(_ approval: ApprovalRequest, bot: String) -> String {
        switch AskFirstAsk(approval)?.kind ?? kind(of: approval) {
        case .buy: String(localized: "Let \(bot) pay for something", comment: "Safety: why Face ID is asked before a payment")
        case .post: String(localized: "Let \(bot) post something", comment: "Safety: why Face ID is asked before a post")
        default: String(localized: "Let \(bot) send something", comment: "Safety: why Face ID is asked before sending")
        }
    }

    /// The kind named in the rule's key, for a request whose words could not be read.
    private static func kind(of approval: ApprovalRequest) -> AskFirstAsk.Kind? {
        let key = approval.patternKey ?? ""
        let word = key.dropFirst(AskFirstAsk.rulePrefix.count).split(separator: ":").first
        return word.flatMap { AskFirstAsk.Kind(rawValue: String($0)) }
    }

    /// The hook a gateway's runtime asks before a yes goes out.
    static func hook(for runtime: GatewayRuntime) -> @MainActor (ApprovalRequest, String) async -> Bool {
        { [weak runtime] approval, profile in
            let shown = runtime?.profiles.first { $0.name == profile }?.shownName
            return await check(approval, bot: shown ?? profile.capitalized)
        }
    }
}
