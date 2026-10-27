#if os(macOS) && NOLLIE_DIRECT
import Foundation
import Testing

/// Nollie Runtime's side of the network filter: what it writes from the filter's reports.
struct RuntimeNetworkFilterTests {
    @Test func reportsBecomeDirectLinesAndRefusedOnesOnlyCount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nollie-filter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("profiles/scout"), withIntermediateDirectories: true)
        let book = PapertrailDoorBook(home: home)
        let link = RuntimeNetworkFilter(book: book, switch: .init(on: true, refuse: false))
        func event(_ bot: String, _ host: String, refused: Bool = false) -> NetworkFilterPolicy.Event {
            .init(at: 1, pid: 3, program: "ssh", host: host, port: 22, transport: "tcp", bot: bot, refused: refused)
        }
        link.record([event("scout", "git.example.com"), event("scout", "blocked.example", refused: true),
                     event("", "nobody.example"), event("unplaced", "x.example"), event("scout", "bad host")])
        book.flush()
        let folder = home.appendingPathComponent("profiles/scout/nollie-workflow/papertrail")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".jsonl") }
        let text = try names.map { try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }.joined()
        #expect(text.contains(#""kind":"direct""#) && text.contains("git.example.com"))
        #expect(!text.contains("blocked.example") && !text.contains("nobody.example") && !text.contains("bad host"))
        #expect(link.refused == 1 && link.unplaced == 3)
        let data = try JSONEncoder().encode([event("scout", "again.example")])
        link.deliver(data)
        link.deliver(Data("not json".utf8))
        book.flush()
        let after = try names.map { try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }.joined()
        #expect(after.contains("again.example"))
    }

    @Test func theSwitchFileIsReadOrOff() throws {
        // Runtime files are read without following links, so the temporary folder's own link is resolved first.
        let temporary = realpath(FileManager.default.temporaryDirectory.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? "/tmp"
        let root = URL(fileURLWithPath: temporary).appendingPathComponent("nollie-switch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(RuntimeNetworkFilter.readSwitch(directory: root) == .off)
        try Data(#"{"version":1,"on":true}"#.utf8).write(to: root.appendingPathComponent("network-filter.json"))
        #expect(RuntimeNetworkFilter.readSwitch(directory: root) == .init(on: true, refuse: false))
    }
}
#endif
