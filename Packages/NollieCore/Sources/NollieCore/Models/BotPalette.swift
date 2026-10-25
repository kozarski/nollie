import Foundation

/// Starting colours for bots nobody coloured yet. Every device uses this one list and the same
/// pick rule, so a bot looks the same on the phone and on the Mac.
public enum BotPalette {
    public static let hexes = [
        "#7C5CFF", "#0A84FF", "#30D158", "#FF9F0A", "#FF375F",
        "#64D2FF", "#BF5AF2", "#FFD60A", "#FF6B35", "#5AC8FA",
    ]

    /// The same name always lands on the same colour.
    public static func defaultHex(for profile: String) -> String {
        let seed: UInt64 = 5381
        let mixed = profile.utf8.reduce(seed) { running, byte in
            running &* 33 &+ UInt64(byte)
        }
        let slot = Int(mixed % UInt64(hexes.count))
        return hexes[slot]
    }
}
