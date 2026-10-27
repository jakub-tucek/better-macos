import Foundation

/// One editable rule per line. JSON quoting preserves unusual text without ambiguity.
enum LinkRuleText {
    struct Result {
        var rules: [LinkRule] = []
        var errors: [String] = []
        var aliases: [String: String] = [:]
    }

    static func field(_ value: String) -> String {
        if !value.isEmpty && !value.contains("->") && !value.contains("→") && !value.contains("\n") && !value.contains("\r") && !value.contains("\"") && value == value.trimmingCharacters(in: .whitespaces) { return value }
        return String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8) ?? "\"\""
    }

    static func render(_ rules: [LinkRule], aliases: [String: String] = [:]) -> String {
        let names = aliases.keys.sorted()
        let declarations = names.map { "alias: \($0) -> \(field(aliases[$0]!))" }
        let lines = rules.map { rule in
            let name = rule.destinationAlias.flatMap { aliases[$0] == rule.target ? $0 : nil }
                ?? names.first { aliases[$0] == rule.target }
            let target = name.map { "@" + $0 } ?? rule.target
            return "\(rule.enabled ? "" : "off: ")\(rule.kind.rawValue): \(field(rule.pattern)) -> \(field(target))"
        }
        return (declarations + (declarations.isEmpty || lines.isEmpty ? [] : [""]) + lines).joined(separator: "\n")
    }

    static func parse(_ text: String, destinations: [LinkDestination], existing: [LinkRule], existingAliases: [String: String] = [:]) -> Result {
        var result = Result()
        var unused = existing
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        func resolve(_ destination: String) -> String? {
            if destinations.contains(where: { $0.id == destination }) || existing.contains(where: { $0.target == destination }) || existingAliases.values.contains(destination) { return destination }
            let matches = destinations.filter { $0.name.caseInsensitiveCompare(destination) == .orderedSame }
            return matches.count == 1 ? matches[0].id : nil
        }
        var declared = Set<String>()
        for (offset, line) in lines.enumerated() {
            let source = line.trimmingCharacters(in: .whitespaces)
            guard source.hasPrefix("alias:") else { continue }
            guard let parts = split(String(source.dropFirst(6))), let name = decode(parts.0),
                  name.range(of: "^[A-Za-z][A-Za-z0-9_-]*$", options: .regularExpression) != nil,
                  let destination = decode(parts.1) else {
                result.errors.append("Line \(offset + 1): use alias: name -> browser or profile ID. Names start with a letter and use letters, digits, _ or -."); continue
            }
            guard declared.insert(name).inserted else { result.errors.append("Line \(offset + 1): duplicate alias ‘\(name)’."); continue }
            guard let target = resolve(destination) else {
                result.errors.append("Line \(offset + 1): unknown or ambiguous alias destination ‘\(destination)’. Aliases must point directly to a browser or profile."); continue
            }
            result.aliases[name] = target
        }
        for (offset, line) in lines.enumerated() {
            var source = line.trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty, !source.hasPrefix("alias:") else { continue }
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
            if destination.hasPrefix("@") {
                guard let resolved = result.aliases[String(destination.dropFirst())] else {
                    result.errors.append("Line \(offset + 1): undefined alias ‘\(destination)’. Add alias: \(destination.dropFirst()) -> browser or profile ID."); continue
                }
                target = resolved
            } else {
                guard let resolved = resolve(destination) else {
                    result.errors.append("Line \(offset + 1): unknown or ambiguous destination ‘\(destination)’. Use an ID from the list below."); continue
                }
                target = resolved
            }
            var rule = LinkRule(enabled: enabled, kind: kind, pattern: pattern, target: target)
            if destination.hasPrefix("@") { rule.destinationAlias = String(destination.dropFirst()) }
            if let index = unused.firstIndex(where: { $0.kind == kind && $0.pattern == pattern && $0.target == target }) { rule.id = unused.remove(at: index).id }
            result.rules.append(rule)
        }
        return result
    }

    static func settingAlias(_ name: String, target: String, in text: String) -> String {
        let declaration = "alias: \(name) -> \(field(target))"
        var lines = text.components(separatedBy: .newlines)
        if let index = lines.firstIndex(where: { line in
            let source = line.trimmingCharacters(in: .whitespaces)
            guard source.hasPrefix("alias:"), let parts = split(String(source.dropFirst(6))) else { return false }
            return decode(parts.0) == name
        }) { lines[index] = declaration }
        else { lines.insert(declaration, at: 0) }
        return lines.joined(separator: "\n")
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
