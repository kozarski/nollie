import Foundation

/// Takes Nollie's add-ons out of a Hermes `config.yaml`'s `plugins.enabled` and `plugins.disabled`
/// lists, line by line, so every other line, comment and setting stays exactly as the person had it.
/// Rewriting the whole file from a parsed copy would lose their comments and layout.
///
/// Only the two simple forms Hermes writes are changed: a block list (`- name` lines) and a one-line
/// list (`[a, b]`). Anything else is left as it is; Hermes skips a listed add-on whose folder is gone.
enum HermesPluginList {
    /// The new text, or nil when nothing in it names one of these add-ons.
    static func removing(_ names: Set<String>, from text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard let plugins = lines.firstIndex(where: { $0.range(of: #"^plugins:\s*(#.*)?$"#, options: .regularExpression) != nil }) else { return nil }
        var end = plugins + 1
        while end < lines.count, lines[end].isEmpty || lines[end].hasPrefix(" ") || lines[end].hasPrefix("\t") || lines[end].hasPrefix("#") { end += 1 }
        var changed = false
        var index = plugins + 1
        var childIndent: Int?
        while index < end {
            let line = lines[index]
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { index += 1; continue }
            if childIndent == nil { childIndent = indent }
            guard indent == childIndent, let key = ["enabled", "disabled"].first(where: { trimmed.hasPrefix($0 + ":") }) else { index += 1; continue }
            let rest = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("[") {
                // enabled: [a, b]
                guard let close = rest.firstIndex(of: "]") else { index += 1; continue }
                let inside = rest[rest.index(after: rest.startIndex)..<close]
                let rawTail = String(rest[rest.index(after: close)...])
                let tail = rawTail.trimmingCharacters(in: .whitespaces)
                guard !inside.contains("["), tail.isEmpty || tail.hasPrefix("#") else { index += 1; continue }
                let items = inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let kept = items.filter { !names.contains(unquoted($0)) }
                if kept.count != items.count {
                    lines[index] = String(repeating: " ", count: indent) + key + ": [" + kept.joined(separator: ", ") + "]" + rawTail
                    changed = true
                }
                index += 1
                continue
            }
            guard rest.isEmpty || rest.hasPrefix("#") else { index += 1; continue }
            // enabled:
            //   - a
            var item = index + 1
            var total = 0, removed = 0
            while item < end {
                let entry = lines[item]
                let entryIndent = entry.prefix { $0 == " " }.count
                let value = entry.trimmingCharacters(in: .whitespaces)
                if value.isEmpty || value.hasPrefix("#") { item += 1; continue }
                guard value.hasPrefix("- ") || value == "-", entryIndent >= indent else { break }
                total += 1
                let name = unquoted(String(value.dropFirst(1)).components(separatedBy: " #").first?.trimmingCharacters(in: .whitespaces) ?? "")
                if names.contains(name) {
                    lines.remove(at: item)
                    end -= 1
                    removed += 1
                    changed = true
                } else {
                    item += 1
                }
            }
            if removed > 0, removed == total {
                // An empty block list would read as null: Hermes expects a list.
                lines[index] = String(repeating: " ", count: indent) + key + ": []" + (rest.isEmpty ? "" : " " + rest)
            }
            index = item
        }
        return changed ? lines.joined(separator: "\n") : nil
    }

    private static func unquoted(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first { text = String(text.dropFirst().dropLast()) }
        return text
    }
}
