import Foundation
import Testing

/// Every string catalog in the repository: each string has German, French, Spanish and Japanese, the
/// placeholders agree with the English, and no translation carries an em-dash. The languages ship only once
/// they are switched on (Docs/languages.md), but they are kept whole from the start.
struct LocalizationCatalogTests {
    static let languages = ["de", "fr", "es", "ja"]

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The catalogs that ship in a target, found by walking the source folders.
    static func catalogs() -> [URL] {
        let folders = ["Apps", "Shared", "Extensions", "Services"].map { repoRoot.appendingPathComponent($0) }
        return folders.flatMap { folder -> [URL] in
            let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
            return (walk?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "xcstrings" }
        }
        .sorted { $0.path < $1.path }
    }

    struct Entry {
        var catalog: String
        var key: String
        var json: [String: Any]
    }

    static func entries() throws -> [Entry] {
        try catalogs().flatMap { url -> [Entry] in
            let data = try Data(contentsOf: url)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = root["strings"] as? [String: [String: Any]] ?? [:]
            return strings.map { Entry(catalog: url.lastPathComponent + " in " + url.deletingLastPathComponent().lastPathComponent,
                                       key: $0.key, json: $0.value) }
        }
    }

    /// Every form of one language's text: a plain string, each plural form, or each phrase of a set.
    /// The plural category comes with it ("" for a plain string).
    static func forms(_ localization: [String: Any]) -> [(category: String, value: String)] {
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            return [("", value)]
        }
        if let set = localization["stringSet"] as? [String: Any], let values = set["values"] as? [String] {
            return values.map { ("", $0) }
        }
        if let variations = localization["variations"] as? [String: Any] {
            return variations.values.compactMap { $0 as? [String: [String: Any]] }.flatMap { cases in
                cases.flatMap { category, nested in forms(nested).map { (category, $0.value) } }
            }
        }
        return []
    }

    /// The format placeholders in a string, as (position, type), so "%2$lld %1$@" and "%@ %lld" match.
    static func placeholders(_ text: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(#@[A-Za-z0-9_]+@|[-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfeEgGcCsSpaA])"#)
        var found = Set<String>()
        var next = 1
        let plain = text.replacingOccurrences(of: "%%", with: "")
        for match in pattern.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            let spec = String(plain[Range(match.range(at: 2), in: plain)!])
            let position: Int
            if let r = Range(match.range(at: 1), in: plain), let n = Int(plain[r]) { position = n } else { position = next; next += 1 }
            found.insert("\(position):\(spec.replacingOccurrences(of: "ld", with: "lld").replacingOccurrences(of: "llld", with: "lld"))")
        }
        return found
    }

    /// Words that stand in for something else in App Shortcuts phrases: ${applicationName}, ${helper}.
    static func phraseSlots(_ text: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"\$\{[A-Za-z]+\}"#)
        return Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) })
    }

    static func translatable(_ entry: Entry) -> Bool {
        (entry.json["shouldTranslate"] as? Bool) != false
    }

    static func english(_ entry: Entry) -> [(category: String, value: String)] {
        let localizations = entry.json["localizations"] as? [String: [String: Any]] ?? [:]
        return localizations["en"].map(forms) ?? [("", entry.key)]
    }

    @Test func catalogsAreFound() throws {
        let names = Set(Self.catalogs().map(\.lastPathComponent))
        #expect(names.isSuperset(of: ["Localizable.xcstrings", "Core.xcstrings", "InfoPlist.xcstrings", "AppShortcuts.xcstrings"]))
        #expect(try Self.entries().count > 1000)
    }

    @Test func everyStringHasEveryLanguage() throws {
        var missing: [String] = []
        for entry in try Self.entries() where Self.translatable(entry) {
            let localizations = entry.json["localizations"] as? [String: [String: Any]] ?? [:]
            for language in Self.languages {
                let found = localizations[language].map(Self.forms) ?? []
                if found.isEmpty || found.contains(where: { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    missing.append("\(language) \(entry.catalog): \(entry.key)")
                }
                // A plural needs at least its "other" form, or one plain string (Japanese has no plural forms).
                if Self.english(entry).contains(where: { !$0.category.isEmpty }),
                   !found.contains(where: { $0.category == "other" || $0.category.isEmpty }) {
                    missing.append("\(language) other form \(entry.catalog): \(entry.key)")
                }
            }
        }
        #expect(missing.isEmpty, "\(missing.count) missing, first: \(missing.prefix(20).joined(separator: "\n"))")
    }

    @Test func placeholdersMatchTheEnglish() throws {
        var wrong: [String] = []
        for entry in try Self.entries() where Self.translatable(entry) {
            let source = Self.english(entry)
            let full = Self.placeholders(source.first(where: { $0.category == "other" || $0.category.isEmpty })?.value ?? entry.key)
            let slots = Self.phraseSlots(entry.key)
            let localizations = entry.json["localizations"] as? [String: [String: Any]] ?? [:]
            for language in Self.languages {
                for form in localizations[language].map(Self.forms) ?? [] {
                    let found = Self.placeholders(form.value)
                    // "one", "two" and the like may leave the number out ("einmal"); everything else must match exactly.
                    let fits = form.category.isEmpty || form.category == "other" ? found == full : found.isSubset(of: full)
                    if !fits { wrong.append("\(language) \(entry.catalog) [\(form.category)] \(entry.key) -> \(form.value)") }
                    if !slots.isEmpty, Self.phraseSlots(form.value) != slots {
                        wrong.append("\(language) phrase slots \(entry.key) -> \(form.value)")
                    }
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) mismatched, first: \(wrong.prefix(20).joined(separator: "\n"))")
    }

    @Test func noEmDashes() throws {
        var found: [String] = []
        for entry in try Self.entries() {
            let localizations = entry.json["localizations"] as? [String: [String: Any]] ?? [:]
            for (language, localization) in localizations {
                for form in Self.forms(localization) where form.value.contains("\u{2014}") {
                    found.append("\(language) \(entry.key) -> \(form.value)")
                }
            }
        }
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    }

    @Test func placeholderReadingWorks() {
        #expect(Self.placeholders("%@ · %lld times") == ["1:@", "2:lld"])
        #expect(Self.placeholders("%2$lld-mal %1$@") == ["1:@", "2:lld"])
        #expect(Self.placeholders("100%% sure") == [])
        #expect(Self.placeholders("%.1f%%") == ["1:.1f"])
    }
}
