import Foundation

/// Preferences of a test's own that leave nothing behind. A suite named like "nollie.tests.<uuid>" becomes a file in
/// ~/Library/Preferences on the Mac, and stays there even after `removePersistentDomain(forName:)`: the system keeps
/// an empty copy and writes it back if the file is deleted. Named by a path instead, the suite lives in a folder of
/// its own under the temporary folder, and once the domain is removed the folder can go for good.
///
/// Throw it away when done: `defer { scratch.throwAway() }`, or keep it as a stored property of a suite and let it go
/// with the suite's instance, which ends each test.
final class ScratchDefaults: @unchecked Sendable {
    let defaults: UserDefaults
    let folder: URL
    private let name: String
    private var thrownAway = false

    init(_ label: String) {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nollie-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        name = folder.appendingPathComponent("preferences").path
        defaults = UserDefaults(suiteName: name)!
    }

    func throwAway() {
        guard !thrownAway else { return }
        thrownAway = true
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: folder)
    }

    deinit { throwAway() }
}
