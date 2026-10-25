import Foundation

/// A helper's own computer, as the nollie-computer add-on reports it
/// (`GET /api/plugins/nollie-computer/own-computer?profile=`).
public struct HelperComputerStatus: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable {
        case off, gettingReady = "getting_ready", ready, asleep, needsYou = "needs_you"
        case turningOff = "turning_off", removing
    }
    /// What Cua on the Mac still needs before a helper can have a computer.
    public enum Setup: String, Decodable, Sendable {
        case ready, noCua = "no_cua", oldCua = "old_cua", cuaNotRunning = "cua_not_running", noRuntime = "no_runtime"
    }

    public var profile: String
    public var on: Bool
    public var state: State
    public var setup: Setup
    public var cuaVersion: String?
    public var computerName: String?
    public var hasComputer: Bool
    public var busy: Bool
    public var message: String?
    /// "exit_node": the Mac sends everything through a Tailscale exit node and Nollie's relay
    /// can't carry this computer's traffic, so it gets no internet. "relay": the exit node is on
    /// and the relay carries the traffic, so nothing needs showing. Nil when nothing is known to be wrong.
    public var internet: String?

    /// The helper's computer can't reach the internet because of the Mac's exit node.
    public var exitNodeBlocksInternet: Bool { internet == "exit_node" }

    public init(profile: String, on: Bool = false, state: State = .off, setup: Setup = .ready, cuaVersion: String? = nil,
                computerName: String? = nil, hasComputer: Bool = false, busy: Bool = false, message: String? = nil) {
        self.profile = profile; self.on = on; self.state = state; self.setup = setup; self.cuaVersion = cuaVersion
        self.computerName = computerName; self.hasComputer = hasComputer; self.busy = busy; self.message = message
    }

    public static let path = "/api/plugins/nollie-computer/own-computer"
}

/// The Mac's automatic Cua setup, as far as the screen needs to know.
public enum HelperComputerSetupRun: Equatable, Sendable {
    public enum Step: String, Sendable {
        case checking, downloading, installing, starting, preparing
        public var title: String {
            switch self {
            case .checking: "Checking Cua"
            case .downloading: "Downloading Cua"
            case .installing: "Installing Cua"
            case .starting: "Starting Cua"
            case .preparing: "Getting Cua ready to run computers"
            }
        }
    }
    case idle
    case working(Step, fraction: Double?)
    /// An older Cua is open and has to quit before it can be updated.
    case needsQuit
    case failed(String)
    /// No setup service on this Mac (or this is the phone): the plain manual path.
    case unavailable
    case done
}

/// One thing the person can do from the computer section.
public enum HelperComputerAction: String, Equatable, Sendable {
    case setUp, update, startCua, finish, getCua, tryAgain, quitCua, notNow
    public var title: String {
        switch self {
        case .setUp: "Set up Cua"
        case .update: "Update Cua"
        case .startCua: "Start Cua"
        case .finish: "Finish setup"
        case .getCua: "Get Cua"
        case .tryAgain: "Try again"
        case .quitCua: "Quit Cua and update"
        case .notNow: "Not now"
        }
    }
}

/// The guided step: one line and at most two pills.
public struct HelperComputerPrompt: Equatable, Sendable {
    public var line: String
    public var action: HelperComputerAction?
    public var secondary: HelperComputerAction?
}

/// The status word on the computer's card.
public enum HelperComputerWord: String, Equatable, Sendable {
    case ready = "Ready", working = "Working", asleep = "Asleep", needsYou = "Needs you"
}

public enum HelperComputerScreen: Equatable, Sendable {
    case loading
    case unavailable(String)
    case off(hasComputer: Bool, busy: Bool)
    case setup(HelperComputerPrompt)
    case settingUp(title: String, fraction: Double?)
    case gettingReady(String)
    case card(HelperComputerWord, note: HelperComputerPrompt?)
}

public enum HelperComputerPresentation {
    public static let title = "A computer of its own"
    public static let line = "Your helper works on its own computer inside your Mac, so your files stay out of reach."

    public static func gettingReady(_ name: String) -> String {
        "Getting \(name)'s computer ready. The first time takes a few minutes."
    }

    public static func cardTitle(_ name: String) -> String { "\(name)'s computer" }

    /// The switch: on while the helper has (or is getting) a computer, or while the person has
    /// asked for one and Cua is being set up for it.
    public static func switchIsOn(_ status: HelperComputerStatus?, wantsOn: Bool) -> Bool {
        guard let status else { return wantsOn }
        if status.state == .turningOff || status.state == .removing { return false }
        return status.on || wantsOn
    }

    /// What Cua needs, in words for this device. The phone can only point at the Mac.
    public static func prompt(for setup: HelperComputerStatus.Setup, onMac: Bool) -> HelperComputerPrompt? {
        switch (setup, onMac) {
        case (.ready, _): return nil
        case (.noCua, true):
            return .init(line: "Your helpers' computers come from Cua, a free tool. Nollie can set it up for you.",
                         action: .setUp, secondary: .notNow)
        case (.noCua, false):
            return .init(line: "Your helpers' computers come from Cua, a free tool on your Mac. Open Nollie on your Mac to set it up.",
                         action: nil, secondary: .notNow)
        case (.oldCua, true):
            return .init(line: "Cua needs a quick update before your helpers can use it.", action: .update, secondary: .notNow)
        case (.oldCua, false):
            return .init(line: "Cua on your Mac needs a quick update. Open Nollie on your Mac to do it.", action: nil, secondary: .notNow)
        case (.cuaNotRunning, true):
            return .init(line: "Cua isn't running. Start it to wake your helpers' computers.", action: .startCua, secondary: nil)
        case (.cuaNotRunning, false):
            return .init(line: "Cua isn't running on your Mac. Open Nollie on your Mac to start it.", action: nil, secondary: nil)
        case (.noRuntime, true):
            return .init(line: "Cua needs one more piece to run computers on this Mac.", action: .finish, secondary: .notNow)
        case (.noRuntime, false):
            return .init(line: "Cua needs one more piece on your Mac. Open Nollie on your Mac to finish.", action: nil, secondary: .notNow)
        }
    }

    public static func screen(status: HelperComputerStatus?, error: String? = nil, wantsOn: Bool, onMac: Bool,
                              run: HelperComputerSetupRun, working: Bool, name: String) -> HelperComputerScreen {
        guard let status else { return error.map { .unavailable($0) } ?? .loading }
        switch status.state {
        case .gettingReady: return .gettingReady(gettingReady(name))
        case .turningOff, .removing: return .off(hasComputer: status.hasComputer, busy: true)
        default: break
        }
        if status.on {
            switch status.state {
            case .asleep: return .card(.asleep, note: nil)
            case .needsYou:
                // A Cua problem gets the same guided step; anything else says what happened.
                if status.setup != .ready, let fix = setupStep(status.setup, onMac: onMac, run: run) {
                    if case .setup(let prompt) = fix { return .card(.needsYou, note: prompt) }
                    return fix
                }
                return .card(.needsYou, note: .init(line: status.message ?? "Something needs a look.", action: nil, secondary: nil))
            default: return .card(working ? .working : .ready, note: nil)
            }
        }
        guard wantsOn else { return .off(hasComputer: status.hasComputer, busy: status.busy) }
        if status.setup == .ready, run == .idle || run == .done { return .gettingReady(gettingReady(name)) }
        return setupStep(status.setup, onMac: onMac, run: run) ?? .gettingReady(gettingReady(name))
    }

    /// The guided step while Cua is set up, one thing at a time.
    static func setupStep(_ setup: HelperComputerStatus.Setup, onMac: Bool, run: HelperComputerSetupRun) -> HelperComputerScreen? {
        guard onMac else { return prompt(for: setup, onMac: false).map { .setup($0) } }
        switch run {
        case .working(let step, let fraction): return .settingUp(title: step.title, fraction: fraction)
        case .needsQuit: return .setup(.init(line: "Cua is open. Nollie needs to close it for a moment to update it.", action: .quitCua, secondary: .notNow))
        case .failed(let reason):
            return .setup(.init(line: reason + " You can also get Cua from cua.ai, then come back here.", action: .getCua, secondary: .tryAgain))
        case .unavailable where setup == .noCua || setup == .oldCua:
            return .setup(.init(line: "Your helpers' computers come from Cua, a free tool. Get it from cua.ai, then come back here.",
                                action: .getCua, secondary: .notNow))
        case .idle, .done, .unavailable: return prompt(for: setup, onMac: true).map { .setup($0) }
        }
    }
}
