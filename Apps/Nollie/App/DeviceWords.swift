import Foundation

/// Copy that adapts to the hardware it runs on: the device's name with "this", touch or pointer
/// verbs, and Settings versus System Settings.
enum DeviceWords {
    /// The few words that differ from one kind of device to the next.
    private struct Vocabulary {
        var device: String
        var settings: String
        var tap: String
        var symbol: String
        var isMac: Bool
    }

    #if os(macOS)
    private static let here = Vocabulary(
        device: "Mac", settings: String(localized: "System Settings", comment: "The Mac's settings app"),
        tap: String(localized: "click", comment: "A verb in the middle of a sentence: click a button"),
        symbol: "laptopcomputer", isMac: true)
    #else
    private static let here: Vocabulary = {
        let isPad = modelIdentifier().hasPrefix("iPad")
        return Vocabulary(
            device: isPad ? "iPad" : "iPhone", settings: String(localized: "Settings", comment: "The iPhone or iPad settings app"),
            tap: String(localized: "tap", comment: "A verb in the middle of a sentence: tap a button"),
            symbol: isPad ? "ipad" : "iphone", isMac: false)
    }()

    /// Something like "iPad14,3". UIKit's device object is main-actor only, and these words are
    /// read from anywhere, so ask the system directly. A simulator reports the host's chip and
    /// names the simulated model in an environment variable.
    private static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var length = 0
        sysctlbyname("hw.machine", nil, &length, nil, 0)
        var buffer = [UInt8](repeating: 0, count: length)
        sysctlbyname("hw.machine", &buffer, &length, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
    #endif

    static let device = here.device
    static let settings = here.settings
    static let tap = here.tap
    static let Tap = here.isMac ? String(localized: "Click", comment: "A verb at the start of a sentence: Click a button")
                                : String(localized: "Tap", comment: "A verb at the start of a sentence: Tap a button")
    static let isMac = here.isMac
    static let symbol = here.symbol

    static let companionBrings = String(localized: "notifications and approvals", comment: "In the middle of a sentence")
    static let CompanionBrings = String(localized: "Notifications and approvals")

    // Pieces for the middle or start of a sentence; %@ is Mac, iPhone or iPad.
    static let this = String(localized: "this \(device)", comment: "In the middle of a sentence; %@ is Mac, iPhone or iPad")
    static let This = String(localized: "This \(device)", comment: "At the start of a sentence; %@ is Mac, iPhone or iPad")
    static let your = String(localized: "your \(device)", comment: "In the middle of a sentence; %@ is Mac, iPhone or iPad")
    static let the = String(localized: "the \(device)", comment: "In the middle of a sentence; %@ is Mac, iPhone or iPad")
    /// Plain device name for the middle of a sentence.
    static let kind = device
}
