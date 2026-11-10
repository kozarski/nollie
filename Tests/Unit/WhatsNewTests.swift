import Foundation
import Testing
@testable import Nollie

/// What's new shows once, after an update, to someone who already had Nollie; never to a new install.
@Suite struct WhatsNewTests {
    private func note(_ version: String) -> WhatsNewNote {
        WhatsNewNote(version: version, lead: "Hello", items: [.init(id: "a", symbol: "sparkles", title: "A", line: "B")])
    }

    private func scratch() -> UserDefaults {
        let name = "whatsnew-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func versionsCompareByNumberNotByLetter() {
        #expect(WhatsNew.isLater("1.10", than: "1.9"))
        #expect(WhatsNew.isLater("1.3.1", than: "1.3"))
        #expect(WhatsNew.isLater("2", than: "1.9.9"))
        #expect(!WhatsNew.isLater("1.3", than: "1.3.0"))
        #expect(!WhatsNew.isLater("1.3.2", than: "1.3.3"))
        #expect(WhatsNew.isLater("1.3.3", than: "0"))
    }

    @Test func aNewInstallIsToldNothingAndAnUpgradeIsToldOnce() {
        let fresh = scratch()
        WhatsNew.launch(hadSetup: false, defaults: fresh, current: "1.3.3")
        #expect(fresh.string(forKey: WhatsNew.seenKey) == "1.3.3")
        #expect(WhatsNew.pending(seen: fresh.string(forKey: WhatsNew.seenKey), current: "1.3.3", notes: [note("1.3.3")]).isEmpty)

        let upgraded = scratch()
        WhatsNew.launch(hadSetup: true, defaults: upgraded, current: "1.3.3")
        #expect(WhatsNew.pending(seen: upgraded.string(forKey: WhatsNew.seenKey), current: "1.3.3", notes: [note("1.3.3")]).map(\.version) == ["1.3.3"])
        WhatsNew.markSeen(defaults: upgraded, current: "1.3.3")
        #expect(WhatsNew.pending(seen: upgraded.string(forKey: WhatsNew.seenKey), current: "1.3.3", notes: [note("1.3.3")]).isEmpty)
        // A later launch never rewrites what was seen.
        WhatsNew.launch(hadSetup: false, defaults: upgraded, current: "1.4")
        #expect(upgraded.string(forKey: WhatsNew.seenKey) == "1.3.3")
    }

    @Test func skippedVersionsComeNewestFirstAndNeverFromTheFuture() {
        let notes = ["1.3.3", "1.4", "1.5", "1.6", "2.0"].map(note)
        #expect(WhatsNew.pending(seen: "1.3.3", current: "1.6", notes: notes).map(\.version) == ["1.6", "1.5", "1.4"])
        #expect(WhatsNew.pending(seen: "1.2", current: "1.6", notes: notes).count == WhatsNew.most)
        #expect(WhatsNew.pending(seen: "1.6", current: "1.6", notes: notes).isEmpty)
        // Nothing remembered yet means launch has not run: show nothing rather than guess.
        #expect(WhatsNew.pending(seen: nil, current: "1.6", notes: notes).isEmpty)
        // A version with no note of its own shows nothing.
        #expect(WhatsNew.pending(seen: "1.6", current: "1.7", notes: notes).isEmpty)
    }

    @Test func readingAgainFindsThisVersionOrTheNewestBeforeIt() {
        let notes = ["1.3.3", "1.4"].map(note)
        #expect(WhatsNew.note(for: "1.3.3", in: notes)?.version == "1.3.3")
        #expect(WhatsNew.note(for: "1.4.1", in: notes)?.version == "1.4")
        #expect(WhatsNew.note(for: "1.4", in: []) == nil)
    }

    @Test func everyNoteIsWholeAndPlain() {
        #expect(!WhatsNew.notes.isEmpty)
        var versions = Set<String>()
        for note in WhatsNew.notes {
            #expect(versions.insert(note.version).inserted, "two notes for \(note.version)")
            #expect(!note.lead.isEmpty && !note.items.isEmpty)
            #expect(Set(note.items.map(\.id)).count == note.items.count)
            // At least one change everyone sees, so the iPhone's note is never empty.
            #expect(note.items.contains { !$0.macOnly })
            for item in note.items {
                for words in [item.title, item.line, item.place ?? "", item.more ?? ""] {
                    #expect(!words.contains("\u{2014}"), "an em dash in \(item.id)")
                }
                #expect(!item.title.isEmpty && !item.line.isEmpty)
            }
        }
    }
}
