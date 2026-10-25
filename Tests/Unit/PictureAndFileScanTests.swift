import Foundation
import Testing
@testable import NollieCore

/// Finding the pictures and files a reply or a tool names, and what is left of the words.
@Suite struct PictureAndFileScanTests {

    // MARK: pictures

    @Test func pictureLinesMarkdownImagesAndLonePathsAreAllFound() {
        let reply = """
        Your graph is ready.
        MEDIA:/srv/bot/.hermes/images/graph.png
        Also as markdown: ![cpu load](/srv/bot/.hermes/images/cpu.jpg)
        /var/tmp/frames/last.webp
        Left alone: ![far away](https://example.org/y.png), /etc/passwd and MEDIA:/var/tmp/readme.txt
        """
        let found = MediaScan.images(in: reply)
        #expect(found.map(\.id) == ["/srv/bot/.hermes/images/graph.png", "/srv/bot/.hermes/images/cpu.jpg", "/var/tmp/frames/last.webp"])
        #expect(found.first?.name == "graph.png")

        let words = MediaScan.textWithoutMedia(reply)
        let leftBehind = ["MEDIA:", "last.webp", "cpu.jpg"].filter { words.contains($0) }
        #expect(leftBehind.isEmpty, "still in the words: \(leftBehind)")
        #expect(words.hasPrefix("Your graph is ready.") && words.contains("Left alone: ![far away](https://example.org/y.png)"))
        #expect(words.contains("Also as markdown: cpu load"))
    }

    @Test func aToolOutputNamesEachPictureOnlyOnce() {
        let output = "Wrote '/Users/me/Pictures/my shot.png' and /var/tmp/one.PNG, then /var/tmp/one.PNG again; log: /var/log/run.log"
        let expectations: [(String, [String])] = [
            // Unquoted paths end at a space, so the one with a space in it is cut short and dropped.
            (output, ["/var/tmp/one.PNG"]),
            ("path=/opt/out/frame.jpeg", ["/opt/out/frame.jpeg"]),
        ]
        for (text, ids) in expectations { #expect(MediaScan.imagePaths(inToolOutput: text).map(\.id) == ids) }
    }

    @Test func imagesAYouRowWasSentWithAreFoundByNameInTheProfilesFolders() {
        let row = "Check these [User attached image: upload_20261101_120000_1.png] [User attached image: upload_20261101_120000_2.jpg]"
        let names = MediaScan.attachedImageNames(in: row)
        #expect(names == ["upload_20261101_120000_1.png", "upload_20261101_120000_2.jpg"])
        #expect(MediaScan.userTextWithoutAttachments(row) == "Check these")

        let careers = MediaScan.attachedImageRef(name: "pic.png", profile: "career")
        let main = MediaScan.attachedImageRef(name: "pic.png", profile: "default")
        #expect(careers.name == "pic.png")
        #expect(careers.candidates == ["~/.hermes/profiles/career/images/pic.png", "~/.hermes/images/pic.png", "~/.hermes/profiles/default/images/pic.png"])
        #expect(main.candidates.first == "~/.hermes/images/pic.png")
    }

    @Test func thePictureStoreKeysOnTheGatewayAndThePath() {
        let key = { (gateway: String, path: String) in MediaStore.key(gateway: gateway, path: path) }
        #expect(key("alpha", "/p.png") == key("alpha", "/p.png"))
        #expect(key("alpha", "/p.png") != key("beta", "/p.png"))
        #expect(key("alpha", "/p.png").count == 32)
        #expect(["/x/photo.HEIC", "/x/photo.md"].map(MediaRef.isImage) == [true, false])
    }

    @Test func aWebPictureStaysForTheMarkdownToDraw() {
        let reply = "Look:\n![old](/home/me/.hermes/images/old.png)\n![web chart](https://example.org/chart.png)\nMEDIA:/home/me/.hermes/images/new.png"
        let words = MediaScan.textWithoutMedia(reply)
        #expect(words == "Look:\nold\n![web chart](https://example.org/chart.png)")
        #expect(Set(MediaScan.images(in: reply).map(\.name)) == ["new.png", "old.png"])
        let drawn = MarkdownParser.blocks(from: words).compactMap { block -> [String]? in
            guard case .image(let alt, let url, _) = block else { return nil }
            return [alt, url]
        }
        #expect(drawn == [["web chart", "https://example.org/chart.png"]])
    }

    @Test func aPathLineKeepsItsPictureDespiteTrailingMarksButProseDoesNot() {
        let named: [(String, [String])] = [("Here:\r\n/tmp/frame.png.\r\n", ["frame.png"]), ("/tmp/frame.png)\n", ["frame.png"]), ("Open /tmp/frame.png please", [])]
        for (text, expected) in named { #expect(MediaScan.images(in: text).map(\.name) == expected, "\(text.debugDescription)") }
        #expect(MediaScan.textWithoutMedia("Look:\r\n/tmp/frame.png.\r\nThanks.") == "Look:\nThanks.")
    }

    // MARK: files

    @Test func everyWayOfNamingAFileGivesOneCard() {
        let reply = """
        Finished. MEDIA:/srv/bot/out/summary.pdf
        Numbers: [the table](</srv/bot/out/the table.csv>) and a bundle, [archive](/srv/bot/out/pack.zip).
        /srv/bot/out/voice.m4a
        ~/Movies/take.mov
        Once more MEDIA:/srv/bot/out/summary.pdf
        """
        let files = MediaScan.files(in: reply)
        #expect(files.map(\.name) == ["summary.pdf", "the table.csv", "pack.zip", "voice.m4a", "take.mov"])
        #expect(files.map { MediaScan.FileKind.of($0.name) } == [.pdf, .table, .archive, .audio, .video])
        #expect(files[1].candidates == ["/srv/bot/out/the table.csv"], "a path with spaces stays whole")
    }

    @Test func picturesAndLookAlikesAreNoFiles() {
        let reply = """
        Shown elsewhere: MEDIA:/srv/bot/out/pic.png and ![diagram](/srv/bot/out/diagram.jpg).
        Nothing under /var/log this time, and /usr/bin is on the path.
        Web: [guide](https://example.org/guide.pdf), version 1.2.3, and a/b.c in prose.
        """
        #expect(MediaScan.files(in: reply).isEmpty)
        for notAFile in ["/var/log", "/srv/bot/out/", "https://example.org/guide.pdf"] { #expect(!MediaScan.isFilePath(notAFile)) }
        for aFile in ["/srv/bot/.hermes/config.yaml", "~/out/todo.md"] { #expect(MediaScan.isFilePath(aFile)) }
    }

    @Test func fileLinesLeaveTheWordsAndALinkKeepsItsText() {
        let reply = "All set.\n\nMEDIA:/srv/bot/out/summary.pdf\n\nFigures: [the table](</srv/bot/out/the table.csv>).\n/srv/bot/out/pack.zip\nEnd."
        #expect(MediaScan.textWithoutMedia(reply) == "All set.\n\nFigures: the table.\nEnd.")
    }
}
