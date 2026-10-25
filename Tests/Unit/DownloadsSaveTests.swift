#if os(macOS)
import Foundation
import Testing
@testable import Nollie

/// Saving a picture into Downloads never overwrites what is already there.
@Suite struct DownloadsSaveTests {
    @Test func aNameInUseGainsANumberBeforeItsExtension() {
        let inUse: Set<String> = ["pic.png", "pic 2.png", "readme", "readme 2"]
        func pick(_ wanted: String) -> String { MediaSave.uniqueName(wanted) { inUse.contains($0) } }
        #expect(pick("new.png") == "new.png")
        #expect(pick("pic.png") == "pic 3.png")
        #expect(pick("readme") == "readme 3")
        let dotted = MediaSave.uniqueName("v1.2.tar") { name in name == "v1.2.tar" }
        #expect(dotted == "v1.2 2.tar")
    }

    @Test func twoSavesOfOneNameLeaveTwoFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original.png")
        try Data([9, 8, 7]).write(to: original)

        func saveOnce() throws -> String {
            let name = MediaSave.uniqueName("copy.png") { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            try FileManager.default.copyItem(at: original, to: folder.appendingPathComponent(name))
            return name
        }
        #expect(try saveOnce() == "copy.png")
        #expect(try saveOnce() == "copy 2.png")
    }

    @Test func aFailureNamesTheFileAndGivesTheReason() {
        let reason = "There is no room left."
        let error = CocoaError(.fileWriteOutOfSpace, userInfo: [NSLocalizedDescriptionKey: reason])
        let message = MediaSave.failureMessage(name: "pic.png", error: error)
        #expect(message == "pic.png was not saved to Downloads. \(reason)")
    }
}
#endif
