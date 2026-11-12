import Foundation
import Testing
@testable import Nollie

struct TestRunPreferencesTests {
    @Test func aTestRunPutsTheAppsPreferencesBackAsItFoundThem() {
        let before: [String: Any] = ["activeConnectionID": "A", "nollie.whatsNew.seen": 3, "bots.lastSeen": ["x": 1]]
        let now: [String: Any] = ["activeConnectionID": "B", "nollie.whatsNew.seen": 3,
                                  "kanban.available.1": "present", "kanban.available.2": "absent"]
        let change = TestRunPreferences.changes(from: before, to: now)
        #expect(change.remove == ["kanban.available.1", "kanban.available.2"])
        #expect(Set(change.put.keys) == ["activeConnectionID", "bots.lastSeen"])
        #expect(change.put["activeConnectionID"] as? String == "A")
        #expect(TestRunPreferences.changes(from: before, to: before).remove.isEmpty)
        #expect(TestRunPreferences.changes(from: before, to: before).put.isEmpty)
    }
}
