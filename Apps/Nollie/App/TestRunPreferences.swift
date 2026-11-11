import Foundation

/// The unit tests run inside the app, so whatever they save lands in the app's own preferences: once
/// hundreds of "kanban.available.<id>" keys. A test run leaves them as it found them: when it ends,
/// keys it added are removed and keys it changed get their old values back.
enum TestRunPreferences {
    static var isTestRun: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    nonisolated(unsafe) private static var found: [String: Any]?

    /// Called first thing at launch. Does nothing outside a test run.
    static func keepAsFound() {
        guard isTestRun, found == nil, let domain = Bundle.main.bundleIdentifier else { return }
        found = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        atexit { TestRunPreferences.putBack() }
    }

    private static func putBack() {
        guard let found, let domain = Bundle.main.bundleIdentifier else { return }
        let now = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        let change = changes(from: found, to: now)
        for key in change.remove { UserDefaults.standard.removeObject(forKey: key) }
        for (key, value) in change.put { UserDefaults.standard.set(value, forKey: key) }
        UserDefaults.standard.synchronize()
    }

    /// What turns `now` back into `before`: the keys to remove and the values to put back.
    static func changes(from before: [String: Any], to now: [String: Any]) -> (remove: [String], put: [String: Any]) {
        let remove = now.keys.filter { before[$0] == nil }.sorted()
        let put = before.filter { key, value in
            guard let current = now[key] else { return true }
            return !(current as AnyObject).isEqual(value)
        }
        return (remove, put)
    }
}
