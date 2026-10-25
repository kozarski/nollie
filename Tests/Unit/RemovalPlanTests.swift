#if os(macOS)
import Foundation
import Testing
import NollieCore
@testable import Nollie

/// Remove Nollie, on a made-up Mac in a private temporary folder: what the plan lists, what it
/// refuses, and what running it leaves. Nothing here touches this Mac's real home.
@MainActor
@Suite struct RemovalPlanTests {
    /// A home with everything Nollie may have made, plus the person's own things around it.
    struct Fixture {
        let home: URL
        var places: RemovalPlaces
        let owned: URL
        let forged: URL
        var support: URL { home.appendingPathComponent("Library/Application Support") }
        var hermes: URL { home.appendingPathComponent(".hermes") }
        var nollie: URL { support.appendingPathComponent("Nollie") }

        init() throws {
            let base = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
            home = URL(fileURLWithPath: String(cString: base)).appendingPathComponent("removal-" + UUID().uuidString)
            free(base)
            let library = home.appendingPathComponent("Library")
            let layout = NolliePaths.Layout(applicationSupport: library.appendingPathComponent("Application Support"),
                                            systemCaches: library.appendingPathComponent("Caches"), sandboxed: false)
            places = RemovalPlaces(edition: .macDirect, home: home, library: library, nollie: layout,
                                   bundleID: "com.coreykozarski.nollie", app: home.appendingPathComponent("Applications/Nollie.app"))
            let id = UUID().uuidString
            owned = layout.setups.appendingPathComponent(id)
            forged = layout.setups.appendingPathComponent(UUID().uuidString)
            try Self.file(owned.appendingPathComponent("ownership.json"), #"{"owner":"com.coreykozarski.nollie","installationID":"\#(id)","schema":"1"}"#)
            try Self.file(owned.appendingPathComponent("home/memories/MEMORY.md"), "the assistant's memory")
            try Self.file(owned.appendingPathComponent("user/.hermes/nollie-computer/owned-spaces.json"), #"{"version":1,"profiles":{"default":"local:nollie-default"}}"#)
            try Self.file(owned.appendingPathComponent("environment/bin/python"), "#!/bin/sh\n", executable: true)
            // Named like a setup, but its record names another setup.
            try Self.file(forged.appendingPathComponent("ownership.json"), #"{"owner":"com.coreykozarski.nollie","installationID":"\#(id)"}"#)
            try Self.file(layout.setups.appendingPathComponent("not-a-setup/notes.txt"), "someone's notes")
            try Self.file(layout.runtimeService.appendingPathComponent("enabled.json"), #"{"version":1,"installationID":"\#(id)"}"#)
            try Self.file(layout.cuaSetup.appendingPathComponent("installed.json"),
                          #"{"version":1,"app":"\#(layout.cua.appendingPathComponent("Cua Spaces.app").path)","madeCuaHome":true}"#)
            try Self.plist(layout.cua.appendingPathComponent("Cua Spaces.app"), id: "com.trycua.spaces.macos")
            try Self.file(layout.transcripts.appendingPathComponent(UUID().uuidString + "/a.json"), "[]")
            try Self.file(layout.logs.appendingPathComponent("Nollie Computer.log"), "log")
            try Self.file(layout.root.appendingPathComponent("Strange/thing.txt"), "not Nollie's")
            try Self.file(library.appendingPathComponent("Caches/com.coreykozarski.nollie/Cache.db"), "cache")
            try Self.file(library.appendingPathComponent("Caches/com.example.other/Cache.db"), "another app")
            try Self.file(library.appendingPathComponent("LaunchAgents/com.coreykozarski.nollie.push.plist"), "<plist/>")
            try Self.file(library.appendingPathComponent("LaunchAgents/com.example.agent.plist"), "<plist/>")
            try Self.plist(places.app!, id: "com.coreykozarski.nollie")
            try Self.plist(home.appendingPathComponent("Applications/Cua Spaces.app"), id: "com.trycua.spaces.macos")
            try Self.file(home.appendingPathComponent(".cua/spaces/one.img"), "computer")
            try Self.file(home.appendingPathComponent("Documents/letter.txt"), "personal")
            // The person's own Hermes, with Nollie's add-ons in it.
            try Self.file(hermes.appendingPathComponent("config.yaml"), "model:\n  default: kept\nplugins:\n  enabled:\n    - nollie-workflow\n    - their-plugin\n")
            try Self.file(hermes.appendingPathComponent("sessions/one.json"), "a chat")
            try Self.file(hermes.appendingPathComponent("memories/MEMORY.md"), "their memory")
            try Self.file(hermes.appendingPathComponent(".env"), "SECRET=1")
            try Self.file(hermes.appendingPathComponent("plugins/nollie-workflow/plugin.yaml"), "name: nollie-workflow")
            try Self.file(hermes.appendingPathComponent("plugins/their-plugin/plugin.yaml"), "name: theirs")
            try Self.file(hermes.appendingPathComponent("plugins/nollie-notreal/plugin.yaml"), "name: lookalike")
            try Self.file(hermes.appendingPathComponent("profiles/scout/config.yaml"), "plugins:\n  enabled: [nollie-reader, web]\n")
            try Self.file(hermes.appendingPathComponent("profiles/scout/plugins/nollie-reader/plugin.yaml"), "name: nollie-reader")
            try Self.file(hermes.appendingPathComponent("profiles/scout/memories/MEMORY.md"), "scout's memory")
            try Self.file(hermes.appendingPathComponent("nollie-workflow/papertrail.json"), "{}")
            try Self.file(hermes.appendingPathComponent("nollie-computer/own-computers.json"), #"{"version":1,"profiles":{}}"#)
            try Self.file(hermes.appendingPathComponent("plugin-backups/nollie-crew-20261020/plugin.yaml"), "old")
            try Self.file(hermes.appendingPathComponent("plugin-backups/their-plugin-20261020/plugin.yaml"), "old")
            try Self.file(hermes.appendingPathComponent("push/hermes_push.py"), "relay")
            try Self.file(hermes.appendingPathComponent("hermes-agent/venv/bin/python"), "#!/bin/sh\n", executable: true)
        }

        static func file(_ url: URL, _ text: String, executable: Bool = false) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }

        static func plist(_ bundle: URL, id: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }

        func remove() { try? FileManager.default.removeItem(at: home) }
    }

    private func urls(_ plan: RemovalPlan) -> [URL] { plan.steps.compactMap(\.url) }
    private func relative(_ url: URL, _ fixture: Fixture) -> String {
        String(url.path.dropFirst(fixture.home.path.count + 1))
    }

    @Test func thePlanListsOnlyWhatNollieMade() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plan = RemovalPlan.build(fixture.places, options: .init(includeCloud: true))
        #expect(plan.parts.map(\.kind) == [.computers, .background, .hermes, .cua, .setup, .files, .keychain, .cloud, .app])
        let touched = Set(urls(plan).map { relative($0, fixture) })
        let expected: Set<String> = [
            "Library/Application Support/Nollie/Setups/\(fixture.owned.lastPathComponent)/user",
            "", // the person's home: the existing Hermes's computers run with it as HOME
            "Library/LaunchAgents/com.coreykozarski.nollie.push.plist",
            ".hermes/plugins/nollie-workflow", ".hermes/profiles/scout/plugins/nollie-reader", ".hermes/nollie-computer",
            ".hermes/nollie-workflow", ".hermes/push", ".hermes/plugin-backups/nollie-crew-20261020",
            ".hermes/config.yaml", ".hermes/profiles/scout/config.yaml",
            "Library/Application Support/Nollie/Cua", ".cua",
            "Library/Application Support/Nollie/Setups/\(fixture.owned.lastPathComponent)",
            "Library/Application Support/Nollie/CuaSetup", "Library/Application Support/Nollie/Caches",
            "Library/Application Support/Nollie/Logs", "Library/Application Support/Nollie/RuntimeService",
            "Library/Application Support/Nollie/Setups", "Library/Application Support/Nollie",
            "Library/Caches/com.coreykozarski.nollie", "Applications/Nollie.app",
        ]
        #expect(touched == expected)
        for step in plan.steps where step.url != nil { #expect(RemovalPlan.permits(step, in: fixture.places), "\(step)") }
        #expect(plan.kept.contains("Cua stays in Applications, because you installed it yourself."))
        #expect(plan.kept.contains("A folder in Nollie's setups that Nollie didn't make stays where it is."))
        #expect(plan.kept.contains("Strange in Nollie's folder isn't something Nollie made, so it stays."))
        // Trash, never delete, inside a person's Hermes; their config is only ever tidied.
        for step in plan.steps {
            guard let url = step.url, url.path.hasPrefix(fixture.hermes.path + "/") else { continue }
            switch step { case .trash, .tidyConfig: break; default: Issue.record("\(step) inside their Hermes") }
        }
    }

    @Test func aPersonsOwnHermesDataIsNeverListedOrPermitted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plan = RemovalPlan.build(fixture.places)
        let theirs = [".hermes", ".hermes/sessions", ".hermes/sessions/one.json", ".hermes/memories", ".hermes/.env",
                      ".hermes/plugins", ".hermes/plugins/their-plugin", ".hermes/plugins/nollie-notreal", ".hermes/profiles",
                      ".hermes/profiles/scout", ".hermes/profiles/scout/memories", ".hermes/plugin-backups/their-plugin-20261020",
                      ".hermes/hermes-agent", "Documents", "Documents/letter.txt", "Library/Caches/com.example.other",
                      "Library/LaunchAgents/com.example.agent.plist", "Applications/Cua Spaces.app", "Library", "Library/Application Support"]
        for path in theirs {
            let url = fixture.home.appendingPathComponent(path)
            #expect(!urls(plan).contains { $0.standardizedFileURL == url.standardizedFileURL }, "\(path)")
            for step in [RemovalStep.delete(url), .trash(url), .deleteIfEmpty(url), .tidyConfig(url), .trashApp(url), .stopPushService(url)] {
                #expect(!RemovalPlan.permits(step, in: fixture.places), "\(step)")
            }
        }
        #expect(!RemovalPlan.permits(.tidyConfig(fixture.hermes.appendingPathComponent("profiles/../config.yaml")), in: fixture.places))
    }

    @Test func pathsOutsideNolliesOwnAreRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let nollie = fixture.nollie
        let refused: [RemovalStep] = [
            .delete(nollie.appendingPathComponent("../../Documents")),
            .delete(URL(fileURLWithPath: "/Applications")),
            .delete(URL(fileURLWithPath: "/")),
            .delete(nollie.appendingPathComponent("Strange")),
            .delete(nollie.appendingPathComponent("Setups/not-a-setup")),
            .delete(fixture.forged),
            .delete(nollie.appendingPathComponent("./Logs")),
            .delete(fixture.home.appendingPathComponent(".cua/../Documents")),
            .trash(fixture.hermes.appendingPathComponent("plugins/../sessions")),
            .trashApp(fixture.home.appendingPathComponent("Applications/Cua Spaces.app")),
            .forgetKeychain("com.apple.something"),
            .releaseComputers(.init(home: fixture.home.appendingPathComponent("Documents"), python: URL(fileURLWithPath: "/usr/bin/python3"), managed: false)),
            .releaseComputers(.init(home: fixture.forged.appendingPathComponent("user"), python: fixture.forged.appendingPathComponent("environment/bin/python"), managed: true)),
        ]
        for step in refused { #expect(!RemovalPlan.permits(step, in: fixture.places), "\(step)") }
        // Contained editions never reach outside their own container.
        var contained = fixture.places
        contained.edition = .contained
        for step in [RemovalStep.trash(fixture.hermes.appendingPathComponent("plugins/nollie-workflow")), .trashApp(fixture.places.app!),
                     .delete(fixture.home.appendingPathComponent(".cua")), .delete(fixture.places.systemFolders[0])] {
            #expect(!RemovalPlan.permits(step, in: contained), "\(step)")
        }
    }

    @Test func linksAreNeverFollowed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fm = FileManager.default
        let outside = fixture.home.appendingPathComponent("Elsewhere")
        // A setup that is a link to a folder elsewhere, carrying a record that would match its name.
        let linkedID = UUID().uuidString
        try Fixture.file(outside.appendingPathComponent("setup/ownership.json"), #"{"owner":"com.coreykozarski.nollie","installationID":"\#(linkedID)"}"#)
        try fm.createSymbolicLink(at: fixture.places.nollie.setups.appendingPathComponent(linkedID), withDestinationURL: outside.appendingPathComponent("setup"))
        // A real setup folder whose ownership record is a link.
        let sneakyID = UUID().uuidString
        let sneaky = fixture.places.nollie.setups.appendingPathComponent(sneakyID)
        try Fixture.file(outside.appendingPathComponent("record.json"), #"{"owner":"com.coreykozarski.nollie","installationID":"\#(sneakyID)"}"#)
        try fm.createDirectory(at: sneaky, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: sneaky.appendingPathComponent("ownership.json"), withDestinationURL: outside.appendingPathComponent("record.json"))
        // A profile's plugins folder that is a link to somewhere else holding a Nollie-named folder.
        try Fixture.file(outside.appendingPathComponent("plugins/nollie-crew/plugin.yaml"), "x")
        try Fixture.file(fixture.hermes.appendingPathComponent("profiles/forager/config.yaml"), "model: {}\n")
        try fm.createSymbolicLink(at: fixture.hermes.appendingPathComponent("profiles/forager/plugins"), withDestinationURL: outside.appendingPathComponent("plugins"))
        // Logs replaced by a link to the person's documents.
        try fm.removeItem(at: fixture.places.nollie.logs)
        try fm.createSymbolicLink(at: fixture.places.nollie.logs, withDestinationURL: fixture.home.appendingPathComponent("Documents"))

        let plan = RemovalPlan.build(fixture.places)
        let listed = urls(plan).map(\.standardizedFileURL)
        for url in [fixture.places.nollie.setups.appendingPathComponent(linkedID), sneaky, fixture.places.nollie.logs,
                    fixture.hermes.appendingPathComponent("profiles/forager/plugins/nollie-crew")] {
            #expect(!listed.contains(url.standardizedFileURL), "\(url.path)")
            #expect(!RemovalPlan.permits(.delete(url), in: fixture.places))
            #expect(!RemovalPlan.permits(.trash(url), in: fixture.places))
        }
        #expect(plan.kept.contains("Logs in Nollie's folder is a link, so Nollie left it alone."))
        #expect(plan.kept.contains("Some of Nollie's add-ons in your Hermes are links, so Nollie left them alone."))
    }

    @Test func aLinkedHermesOrNollieFolderIsLeftWhole() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fm = FileManager.default
        let realHermes = fixture.home.appendingPathComponent("Disk/hermes")
        try fm.createDirectory(at: realHermes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: fixture.hermes, to: realHermes)
        try fm.createSymbolicLink(at: fixture.hermes, withDestinationURL: realHermes)
        let realNollie = fixture.home.appendingPathComponent("Disk/nollie")
        try fm.moveItem(at: fixture.nollie, to: realNollie)
        try fm.createSymbolicLink(at: fixture.nollie, withDestinationURL: realNollie)
        let plan = RemovalPlan.build(fixture.places)
        #expect(!plan.parts.contains { [.hermes, .setup, .cua, .computers].contains($0.kind) })
        #expect(!urls(plan).contains { $0.path.hasPrefix(fixture.nollie.path) || $0.path.hasPrefix(fixture.hermes.path) })
        #expect(plan.kept.contains("Your Hermes folder is a link, so Nollie left its add-ons there. You can remove them in Hermes."))
        #expect(plan.kept.contains("Nollie's folder is a link, so Nollie left it and what it points to alone."))
        #expect(!RemovalPlan.permits(.delete(fixture.nollie.appendingPathComponent("Logs")), in: fixture.places))
        #expect(!RemovalPlan.permits(.trash(fixture.hermes.appendingPathComponent("plugins/nollie-workflow")), in: fixture.places))
    }

    @Test func cuaAndItsStateGoOnlyWhenNollieInstalledIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.places.nollie.cuaSetup.appendingPathComponent("installed.json"))
        let plan = RemovalPlan.build(fixture.places)
        #expect(!plan.parts.contains { $0.kind == .cua })
        #expect(!urls(plan).contains { $0.standardizedFileURL == fixture.places.cuaHome.standardizedFileURL })
        #expect(!RemovalPlan.permits(.delete(fixture.places.cuaHome), in: fixture.places))
        // A receipt naming a Cua anywhere but Nollie's folder counts for nothing.
        try Fixture.file(fixture.places.nollie.cuaSetup.appendingPathComponent("installed.json"),
                         #"{"version":1,"app":"/Applications/Cua Spaces.app","madeCuaHome":true}"#)
        #expect(RemovalPlan.cuaReceipt(fixture.places) == nil)
        #expect(!RemovalPlan.permits(.delete(fixture.places.cuaHome), in: fixture.places))
    }

    @Test func theAppAndContainedEditionsAskForLess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(!RemovalPlan.build(fixture.places, options: .init(keepApp: true)).parts.contains { $0.kind == .app })
        #expect(!RemovalPlan.build(fixture.places).parts.contains { $0.kind == .cloud })
        var contained = fixture.places
        contained.edition = .contained
        contained.app = nil
        let plan = RemovalPlan.build(contained)
        #expect(plan.parts.map(\.kind) == [.setup, .files, .keychain])
        #expect(!plan.steps.contains { if case .stopRuntime = $0 { true } else { false } })
        #expect(!urls(plan).contains { $0.path.hasPrefix(fixture.hermes.path) || $0.path.hasPrefix(fixture.home.appendingPathComponent(".cua").path) })
    }

    // MARK: Running

    final class FakeServices: RemovalServices {
        var calls: [String] = []
        var trashed: [URL] = []
        func stopRuntime() async -> String? { calls.append("stopRuntime"); return nil }
        func unregisterRuntime() async -> String? { calls.append("unregisterRuntime"); return nil }
        func unregisterNotifications() async -> String? { calls.append("unregisterNotifications"); return nil }
        func releaseComputers(_ hermes: RemovalHermes) async -> String? { calls.append("release \(hermes.managed)"); return nil }
        func stopPushService() async -> String? { calls.append("stopPush"); return nil }
        func trash(_ url: URL) -> String? {
            trashed.append(url)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        func forgetKeychain(_ service: String) -> String? { calls.append("keychain " + service); return nil }
        func clearSettings() { calls.append("settings") }
        func deleteCloudData() async -> String? { calls.append("cloud"); return nil }
    }

    @Test func runningItLeavesOnlyWhatIsntNollies() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plan = RemovalPlan.build(fixture.places)
        let services = FakeServices()
        let runner = RemovalRunner(plan: plan, places: fixture.places, services: services)
        await runner.run()
        #expect(runner.phase == .finished)
        #expect(runner.troubles == [])
        #expect(runner.movedAppToTheTrash)
        let fm = FileManager.default
        func there(_ path: String) -> Bool { fm.fileExists(atPath: fixture.home.appendingPathComponent(path).path) }
        for gone in [".hermes/plugins/nollie-workflow", ".hermes/nollie-workflow", ".hermes/push", ".cua",
                     "Library/Application Support/Nollie/Setups/\(fixture.owned.lastPathComponent)",
                     "Library/Application Support/Nollie/Caches", "Library/Application Support/Nollie/Cua",
                     "Library/Caches/com.coreykozarski.nollie", "Library/LaunchAgents/com.coreykozarski.nollie.push.plist",
                     "Applications/Nollie.app"] {
            #expect(!there(gone), "\(gone)")
        }
        for kept in [".hermes/sessions/one.json", ".hermes/memories/MEMORY.md", ".hermes/.env", ".hermes/plugins/their-plugin",
                     ".hermes/plugins/nollie-notreal", ".hermes/profiles/scout/memories/MEMORY.md", "Documents/letter.txt",
                     "Library/Caches/com.example.other/Cache.db", "Library/LaunchAgents/com.example.agent.plist",
                     "Applications/Cua Spaces.app", "Library/Application Support/Nollie/Strange/thing.txt",
                     "Library/Application Support/Nollie/Setups/not-a-setup/notes.txt",
                     "Library/Application Support/Nollie/Setups/\(fixture.forged.lastPathComponent)/ownership.json"] {
            #expect(there(kept), "\(kept)")
        }
        let config = try String(contentsOf: fixture.hermes.appendingPathComponent("config.yaml"), encoding: .utf8)
        #expect(config == "model:\n  default: kept\nplugins:\n  enabled:\n    - their-plugin\n")
        let backups = try fm.contentsOfDirectory(atPath: fixture.hermes.path).filter { $0.hasPrefix("config.yaml.bak-nollie-removal-") }
        #expect(backups.count == 1)
        #expect(try String(contentsOf: fixture.hermes.appendingPathComponent("profiles/scout/config.yaml"), encoding: .utf8) == "plugins:\n  enabled: [web]\n")
        #expect(services.calls.prefix(5) == ["release true", "release false", "stopRuntime", "unregisterRuntime", "unregisterNotifications"])
        #expect(services.calls.contains("settings"))
        #expect(!services.calls.contains("cloud"))
    }

    @Test func aForgedStepIsRefusedWhenItRuns() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let documents = fixture.home.appendingPathComponent("Documents")
        let plan = RemovalPlan(parts: [.init(kind: .files, title: "x", detail: nil,
                                             steps: [.delete(documents), .trash(fixture.hermes.appendingPathComponent("sessions"))])], kept: [])
        let services = FakeServices()
        let runner = RemovalRunner(plan: plan, places: fixture.places, services: services)
        await runner.run()
        #expect(runner.troubles.count == 1)
        #expect(FileManager.default.fileExists(atPath: documents.appendingPathComponent("letter.txt").path))
        #expect(FileManager.default.fileExists(atPath: fixture.hermes.appendingPathComponent("sessions/one.json").path))
        #expect(services.trashed.isEmpty)
    }

    @Test func aPretendRunTouchesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let services = FakeServices()
        let runner = RemovalRunner(plan: RemovalPlan.build(fixture.places), places: fixture.places, services: services, pretend: true)
        await runner.run()
        #expect(runner.lines.allSatisfy { $0.state == .done })
        #expect(services.calls.isEmpty && services.trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.places.nollie.logs.path))
    }

    // MARK: Coming back

    @Test func aReinstalledNollieFindsWhatTheEarlierCopyLeft() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = fixture.owned.lastPathComponent
        // Nothing to offer while this copy already knows the setup and the runtime left no note.
        #expect(RemovalLeftovers.find(fixture.places, selected: id) == nil)
        // Settings were cleared, or the runtime noticed the app was gone.
        #expect(RemovalLeftovers.find(fixture.places, selected: nil)?.installationID == UUID(uuidString: id))
        let note = fixture.places.nollie.runtimeService.appendingPathComponent(RemovalLeftovers.noteName)
        try Fixture.file(note, #"{"version":1,"at":0,"app":"/Applications/Nollie.app"}"#)
        #expect(RemovalLeftovers.find(fixture.places, selected: id) == RemovalLeftovers(installationID: UUID(uuidString: id)!, note: note))
        var contained = fixture.places
        contained.edition = .contained
        #expect(RemovalLeftovers.find(contained, selected: nil) == nil)
    }

    @Test func everyVisibleLineIsPlain() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plan = RemovalPlan.build(fixture.places, options: .init(includeCloud: true))
        let demo = RemovalPlan.demo(RemovalPlan.demoPlaces, options: .init(includeCloud: true))
        for line in plan.parts.flatMap({ [$0.title, $0.detail ?? ""] }) + plan.kept + demo.parts.map(\.title) {
            #expect(!line.contains("\u{2014}"), "\(line)")
            #expect(line.count < 140, "\(line)")
        }
    }
}
#endif
