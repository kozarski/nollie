import Foundation
import Testing

struct ScratchDefaultsTests {
    @Test func throwingAwayLeavesNothingBehind() throws {
        let scratch = ScratchDefaults("scratch-check")
        scratch.defaults.set("kept", forKey: "a")
        #expect(scratch.defaults.string(forKey: "a") == "kept")
        scratch.throwAway()
        #expect(!FileManager.default.fileExists(atPath: scratch.folder.path))
        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        #expect(!left.contains { $0.contains("scratch-check") })
    }
}
