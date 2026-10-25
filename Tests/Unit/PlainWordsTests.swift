import Foundation
import Testing
@testable import NollieCore

/// A reply turned into plain words, for the one-line preview.
@Suite struct PlainWordsTests {
    @Test func taskBoxesBecomeDoneAndToDo() {
        let said = PlainReply.text("- [x] Counted the files\n- [ ] Write the cleanup rule\n* [X] Drafted the command")
        #expect(said == "Done: Counted the files. To do: Write the cleanup rule. Done: Drafted the command.")
        #expect(!said.contains("["))
        // Brackets that are no task box stay as words.
        #expect(PlainReply.text("Read [the notes](https://example.org/n) and [2].") == "Read the notes and [2].")
    }

    @Test func markdownTurnsToSentencesAndBlocksToShortNotes() {
        let reply = """
        ## What turned up

        `/var/cache` takes **6.1 GB**, mostly [old builds](https://example.org) from before August:

        - `builds/tmp.*` — 3.4 GB
        - crash dumps, *the oldest from May*

        ```bash
        find /var/cache -mtime +60 -delete
        ```

        | Folder | Size |
        |---|---|
        | builds | 3.4 GB |

        ```html
        <canvas id="pad"></canvas>
        ```

        Tell me and I'll clear it.
        """
        let plain = PlainReply.text(reply)
        #expect(plain.hasPrefix("What turned up. /var/cache takes 6.1 GB, mostly old builds from before August:"))
        #expect(plain.contains("builds/tmp.* — 3.4 GB."))
        #expect(plain.contains("crash dumps, the oldest from May."))
        for note in [PlainReply.codeOmitted, PlainReply.tableOmitted, PlainReply.cardOmitted] { #expect(plain.contains(note)) }
        for mark in ["```", "**", "](", "|"] { #expect(!plain.contains(mark), "\(mark) leaked") }
        #expect(plain.hasSuffix("Tell me and I'll clear it."))
    }

    @Test func frontMatterIsSkipped() {
        #expect(PlainReply.text("---\nSummary: a\ntitle: b\n---\nHi there.") == "Hi there.")
        #expect(PlainReply.text("---\nHi there.") == "Hi there.")
        // A rule in the middle is not front matter.
        #expect(PlainReply.text("First.\n---\nkey: v\n---\nLast.") == "First. key: v Last.")
    }

    @Test func picturesAreSeenNotRead() {
        let reply = "The usage before and after:\nMEDIA:/home/x/.hermes/images/use.png\n/tmp/snap.png\nEnd."
        #expect(PlainReply.text(reply) == "The usage before and after: End.")
        #expect(PlainReply.text("Look MEDIA:/a/b.png here.") == "Look here.")
    }

    @Test func openFencesAndImagesAreHandled() {
        #expect(PlainReply.text("Try:\n```python\nprint(2)") == "Try: " + PlainReply.codeOmitted)
        #expect(PlainReply.text("Look ![the plot](p.png) and ![](q.png).") == "Look the plot and an image.")
        #expect(PlainReply.text("") == "")
    }

    @Test func aTableWithoutOuterPipesIsOneNoteWhileAPipeInProseIsRead() {
        // The app draws tables with no outer pipes, so the preview skips them too.
        #expect(PlainReply.text("Sizes:\n\nx | y\n--|--\n1 | 2\n\nDone.") == "Sizes: " + PlainReply.tableOmitted + " Done.")
        let prose = PlainReply.text("Either X | or Y, you pick.\nNext.")
        #expect(prose.contains(PlainReply.tableOmitted) == false)
        #expect(prose.hasPrefix("Either X") && prose.hasSuffix("Next."))
    }

    @Test func streamingHoldsAPossibleHeaderUntilTheDelimiterRowDecides() {
        var table = PlainReply.Incremental()
        let first = table.feed("Name | Size\n")
        var said = first
        #expect(first.isEmpty)
        said += table.feed("---|---\nbackups | 3 GB\n\nThat is it.\n")
        #expect(said == [PlainReply.tableOmitted, "That is it."])

        var notATable = PlainReply.Incremental()
        #expect(notATable.feed("Pick X | Y\n").isEmpty)
        let released = notATable.feed("Then go.\n")
        #expect(released.count == 2 && released[0].hasPrefix("Pick X") && released[1] == "Then go.")

        // A pipe line that ends the reply with no newline is still said.
        #expect(PlainReply.text("Either X | or Y.").hasPrefix("Either X"))
        var last = PlainReply.Incremental()
        #expect(last.feed("Either X | or Y.").isEmpty)
        #expect(last.finish().first?.hasPrefix("Either X") == true)
    }
}
