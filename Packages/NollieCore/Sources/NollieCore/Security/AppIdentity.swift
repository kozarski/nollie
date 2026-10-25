import Foundation

/// The shared identity used by Nollie and its extensions.
public enum AppIdentity {
    public static let bundleID = "com.coreykozarski.nollie"
    public static let urlScheme = "nollie"

    public static func acceptsURLScheme(_ scheme: String?) -> Bool {
        scheme == urlScheme
    }
}
