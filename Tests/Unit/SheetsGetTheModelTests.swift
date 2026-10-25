import Foundation
import SwiftUI
import Testing
@testable import Nollie
@testable import NollieCore

/// Sheets, full-screen covers, popovers and context-menu previews in the app's views must all hand
/// their content the app model via `withAppModel()`. The iPhone app run on a Mac once crashed
/// when a sheet appeared and its content had no AppModel in the environment (the message
/// was that no ObservableObject of type AppModel was found, 1.3 build 5). A presentation added
/// later without the call would bring the crash back, which is why the source files get scanned.
@MainActor @Suite struct SheetsGetTheModelTests {
    /// A view that takes the model from its environment, like most sheet content.
    private struct NeedsModel: View {
        @Environment(AppModel.self) private var model
        static var lastSeen: AppModel?
        var body: some View {
            let _ = { Self.lastSeen = model }()
            Color.clear.frame(width: 2, height: 2)
        }
    }

    @Test func theModifierSuppliesTheModelWhenNothingAboveDoes() {
        NeedsModel.lastSeen = nil
        // Rendered alone, with no environment from a parent: the position a presentation's
        // content is in when its presenter's environment did not carry over.
        _ = ImageRenderer(content: NeedsModel().withAppModel()).cgImage
        #expect(NeedsModel.lastSeen === AppModel.shared)
    }

    @Test func everyPresentationInBothAppsPassesTheModelOn() throws {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var sources: [URL] = []
        for folder in ["Apps/Nollie", "Apps/Mac"] {
            let dir = repoRoot.appendingPathComponent(folder)
            let walker = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil), "cannot read \(dir.path)")
            let swiftFiles = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            try #require(!swiftFiles.isEmpty, "no Swift files under \(dir.path)")
            sources += swiftFiles
        }

        var seen = 0
        var lacking: [String] = []
        for file in sources {
            for hit in PresentationFinder.hits(in: try String(contentsOf: file, encoding: .utf8)) {
                seen += 1
                if !hit.body.contains("withAppModel()") { lacking.append("\(file.lastPathComponent):\(hit.line) \(hit.kind)") }
            }
        }
        #expect(seen > 30, "only \(seen) presentations were found, so the finder is probably blind")
        #expect(lacking.isEmpty, "these presentations do not pass the model on: \(lacking.joined(separator: ", "))")
    }

    @Test func theFinderReadsEveryKindAndIgnoresCommentsAndStrings() {
        let sample = [
            "struct Screen: View {",
            "    var body: some View {",
            "        // .sheet(isPresented: $hidden) { NotCounted() }",
            "        Text(\"looks like .sheet( in text { }\")",
            "            .sheet(isPresented: Binding(get: { a && b }, set: { _ in })) { First().withAppModel() }",
            "            .sheet(item: $pick, onDismiss: { done() }) { picked in",
            "                if let r { Second(r) }",
            "            }",
            "            .fullScreenCover(isPresented: $cover) { Third(f: { $0 }).withAppModel() }",
            "            .popover(isPresented: $pop, arrowEdge: .bottom) { Fourth(\"}\") }",
            "            .contextMenu { Button(\"x\") {} } preview: { Fifth().withAppModel() }",
            "    }",
            "}",
        ].joined(separator: "\n")
        let hits = PresentationFinder.hits(in: sample)
        let summary = hits.map { "\($0.kind)@\($0.line):\($0.body.contains("withAppModel()") ? "passes" : "lacks")" }
        #expect(summary == ["sheet@5:passes", "sheet@6:lacks", "fullScreenCover@9:passes", "popover@10:lacks", "preview@11:passes"])
        #expect(hits[1].body.contains("Second(r)"))
    }
}

/// Finds the content closure of each presentation in Swift source: `.sheet(...)`, `.popover(...)`,
/// `.fullScreenCover(...)` (each with its trailing closure), and the `preview:` closure of a
/// context menu. Comments, and whatever sits inside strings, are masked first; a brace within a string
/// therefore can't unbalance the search, and a sheet that is commented out gets ignored.
enum PresentationFinder {
    struct Hit { let kind: String; let line: Int; let body: String }

    private static let modifiers = ["fullScreenCover", "popover", "sheet"]
    private static let blanks: Set<Character> = [" ", "\n"]

    static func hits(in source: String) -> [Hit] {
        let text = Array(mask(source))
        var found: [Hit] = []
        var at = 0
        while at < text.count {
            if let name = modifierName(startingAt: at, in: text) {
                let argsOpen = at + 1 + name.count
                guard let argsClose = partner(ofBracketAt: argsOpen, in: text) else { break }
                let next = skipBlanks(from: argsClose + 1, in: text)
                let body: String
                if next < text.count, text[next] == "{", let end = partner(ofBracketAt: next, in: text) {
                    body = String(text[next...end])
                } else {
                    // Content passed in as an ordinary argument, not as a trailing closure.
                    body = String(text[argsOpen...argsClose])
                }
                found.append(Hit(kind: name, line: lineNumber(at, in: text), body: body))
                at = argsOpen + 1
            } else if isPreviewLabel(at, in: text) {
                let next = skipBlanks(from: at + "preview:".count, in: text)
                if next < text.count, text[next] == "{", let end = partner(ofBracketAt: next, in: text) {
                    found.append(Hit(kind: "preview", line: lineNumber(at, in: text), body: String(text[next...end])))
                }
                at += "preview:".count
            } else {
                at += 1
            }
        }
        return found
    }

    private static func modifierName(startingAt at: Int, in text: [Character]) -> String? {
        guard text[at] == "." else { return nil }
        return modifiers.first { name in
            let nameEnd = at + 1 + name.count
            return nameEnd < text.count && text[nameEnd] == "(" && String(text[(at + 1)..<nameEnd]) == name
        }
    }

    private static func isPreviewLabel(_ at: Int, in text: [Character]) -> Bool {
        let label = Array("preview:")
        guard at > 0, at + label.count <= text.count, Array(text[at..<(at + label.count)]) == label else { return false }
        let before = text[at - 1]
        return !(before.isLetter || before.isNumber || before == "_")
    }

    private static func skipBlanks(from start: Int, in text: [Character]) -> Int {
        var at = start
        while at < text.count, blanks.contains(text[at]) { at += 1 }
        return at
    }

    /// The index of the bracket closing the one at `open`, counting only that bracket's own kind.
    private static func partner(ofBracketAt open: Int, in text: [Character]) -> Int? {
        let pairs: [Character: Character] = ["(": ")", "{": "}"]
        guard let closer = pairs[text[open]] else { return nil }
        var depth = 0
        for at in open..<text.count {
            if text[at] == text[open] { depth += 1 }
            else if text[at] == closer {
                depth -= 1
                if depth == 0 { return at }
            }
        }
        return nil
    }

    private static func lineNumber(_ index: Int, in text: [Character]) -> Int {
        1 + text[..<index].filter { $0 == "\n" }.count
    }

    // MARK: masking

    private enum Mode {
        case code
        case lineComment
        case blockComment(depth: Int)
        case string(multiline: Bool)
        case interpolation(depth: Int, multiline: Bool)
    }

    /// The source with comments and string contents (interpolations included) replaced by
    /// spaces. Line breaks stay so line numbers still count.
    static func mask(_ source: String) -> String {
        let chars = Array(source)
        var result = chars
        var mode = Mode.code
        var at = 0

        func wipe(_ index: Int) { if index < chars.count, chars[index] != "\n" { result[index] = " " } }
        func ahead(_ offset: Int) -> Character? { at + offset < chars.count ? chars[at + offset] : nil }

        while at < chars.count {
            let c = chars[at]
            switch mode {
            case .code:
                if c == "/", ahead(1) == "/" { mode = .lineComment; wipe(at); wipe(at + 1); at += 2 }
                else if c == "/", ahead(1) == "*" { mode = .blockComment(depth: 1); wipe(at); wipe(at + 1); at += 2 }
                else if c == "\"" {
                    let multiline = ahead(1) == "\"" && ahead(2) == "\""
                    mode = .string(multiline: multiline)
                    at += multiline ? 3 : 1
                } else { at += 1 }
            case .lineComment:
                if c == "\n" { mode = .code } else { wipe(at) }
                at += 1
            case .blockComment(let depth):
                if c == "/", ahead(1) == "*" { mode = .blockComment(depth: depth + 1); wipe(at); wipe(at + 1); at += 2 }
                else if c == "*", ahead(1) == "/" {
                    wipe(at); wipe(at + 1); at += 2
                    mode = depth == 1 ? .code : .blockComment(depth: depth - 1)
                } else { wipe(at); at += 1 }
            case .string(let multiline):
                if c == "\\", ahead(1) == "(" {
                    wipe(at); wipe(at + 1)
                    mode = .interpolation(depth: 1, multiline: multiline)
                    at += 2
                } else if c == "\\" {
                    wipe(at); wipe(at + 1); at += 2
                } else if c == "\"", !multiline {
                    mode = .code; at += 1
                } else if c == "\"", ahead(1) == "\"", ahead(2) == "\"" {
                    mode = .code; at += 3
                } else if c == "\n", !multiline {
                    mode = .code; at += 1
                } else { wipe(at); at += 1 }
            case .interpolation(let depth, let multiline):
                wipe(at)
                if c == "(" { mode = .interpolation(depth: depth + 1, multiline: multiline) }
                else if c == ")" { mode = depth == 1 ? .string(multiline: multiline) : .interpolation(depth: depth - 1, multiline: multiline) }
                at += 1
            }
        }
        return String(result)
    }
}
