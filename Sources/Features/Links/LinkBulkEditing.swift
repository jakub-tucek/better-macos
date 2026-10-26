import Foundation

enum LinkBulkAction {
    case destination(String), enabled(Bool), delete
}

extension LinkRoutingConfig {
    mutating func editRules(_ ids: Set<UUID>, action: LinkBulkAction) {
        if case .delete = action { rules.removeAll { ids.contains($0.id) }; return }
        for index in rules.indices where ids.contains(rules[index].id) {
            switch action {
            case .destination(let target): rules[index].target = target
            case .enabled(let enabled): rules[index].enabled = enabled
            case .delete: break
            }
        }
    }
}

/// Pure preparation: opening the editor and pasting never writes rules or opens URLs.
struct LinkBulkImport {
    var patterns: [String] = []
    var invalidLines: [Int] = []
    var duplicates = 0

    init(text: String, kind: LinkRuleKind, target: String, existing: [LinkRule]) {
        var seen = Set(existing.filter { $0.kind == kind && $0.target == target }.map { $0.pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        for (index, line) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).enumerated() {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            let pattern: String
            if kind == .domain {
                let candidate = value.contains("://") ? value : "https://" + value
                guard !value.contains("*"), !value.contains(where: { $0.isWhitespace }),
                      let url = LinkURL.parse(candidate), let host = url.host,
                      url.user == nil, url.password == nil, url.port == nil else {
                    invalidLines.append(index + 1); continue
                }
                pattern = host.lowercased() + (url.path == "/" ? "" : url.path)
            } else {
                pattern = kind == .pattern ? LinkRule.strippingScheme(value) : value
            }
            guard !pattern.isEmpty else { invalidLines.append(index + 1); continue }
            if seen.insert(pattern.lowercased()).inserted { patterns.append(pattern) }
            else { duplicates += 1 }
        }
    }

    var canAdd: Bool { invalidLines.isEmpty && !patterns.isEmpty }
}
