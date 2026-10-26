import Foundation

/// One editable rule per line. JSON quoting preserves unusual text without ambiguity.
enum LinkRuleText {
    struct Result {
        var rules: [LinkRule] = []
        var errors: [String] = []
    }

    static func field(_ value: String) -> String {
        if !value.isEmpty && !value.contains("->") && !value.contains("→") && !value.contains("\n") && !value.contains("\r") && !value.contains("\"") && value == value.trimmingCharacters(in: .whitespaces) { return value }
        return String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8) ?? "\"\""
    }

    static func render(_ rules: [LinkRule]) -> String {
        rules.map { "\($0.enabled ? "" : "off: ")\($0.kind.rawValue): \(field($0.pattern)) -> \(field($0.target))" }.joined(separator: "\n")
    }

    static func parse(_ text: String, destinations: [LinkDestination], existing: [LinkRule]) -> Result {
        var result = Result()
        var unused = existing
        for (offset, line) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).enumerated() {
            var source = line.trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty else { continue }
            var enabled = true
            if source.hasPrefix("off:") { enabled = false; source = String(source.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            var kind = LinkRuleKind.domain
            for candidate in LinkRuleKind.allCases where source.hasPrefix(candidate.rawValue + ":") {
                kind = candidate; source = String(source.dropFirst(candidate.rawValue.count + 1)).trimmingCharacters(in: .whitespaces); break
            }
            guard let parts = split(source), let pattern = decode(parts.0), let destination = decode(parts.1) else {
                result.errors.append("Line \(offset + 1): use match -> browser or profile."); continue
            }
            let target: String
            if destinations.contains(where: { $0.id == destination }) || existing.contains(where: { $0.target == destination }) {
                target = destination
            } else {
                let matches = destinations.filter { $0.name.caseInsensitiveCompare(destination) == .orderedSame }
                guard matches.count == 1 else {
                    result.errors.append("Line \(offset + 1): unknown or ambiguous destination ‘\(destination)’. Use an ID from the list below."); continue
                }
                target = matches[0].id
            }
            var rule = LinkRule(enabled: enabled, kind: kind, pattern: pattern, target: target)
            if let index = unused.firstIndex(where: { $0.kind == kind && $0.pattern == pattern && $0.target == target }) { rule.id = unused.remove(at: index).id }
            result.rules.append(rule)
        }
        return result
    }

    private static func decode(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") { return try? JSONDecoder().decode(String.self, from: Data(value.utf8)) }
        return value
    }

    private static func split(_ source: String) -> (String, String)? {
        var quoted = false
        var escaped = false
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if escaped { escaped = false }
            else if quoted && character == "\\" { escaped = true }
            else if character == "\"" { quoted.toggle() }
            else if !quoted && (source[index...].hasPrefix("->") || character == "→") {
                return (String(source[..<index]), String(source[source.index(index, offsetBy: character == "→" ? 1 : 2)...]))
            }
            index = source.index(after: index)
        }
        return nil
    }
}
