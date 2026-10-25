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
        device: "Mac", settings: "System Settings", tap: "click", symbol: "laptopcomputer", isMac: true)
    #else
    private static let here: Vocabulary = {
        let isPad = modelIdentifier().hasPrefix("iPad")
        return Vocabulary(
            device: isPad ? "iPad" : "iPhone", settings: "Settings", tap: "tap",
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
    static let Tap = here.tap.capitalized
    static let isMac = here.isMac
    static let symbol = here.symbol

    static let companionBrings = "notifications and approvals"
    static let CompanionBrings = "Notifications and approvals"

    static let this = "this " + device
    static let This = "This " + device
    static let your = "your " + device
    static let the = "the " + device
    /// Plain device name for the middle of a sentence.
    static let kind = device
}
