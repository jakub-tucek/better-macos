import Foundation

/// Raw values are persisted; keep them stable.
enum LinkRuleKind: String, Codable, CaseIterable, Identifiable {
    case domain, contains, pattern
    var id: String { rawValue }
    var title: String {
        switch self {
        case .domain: return "Domain"
        case .contains: return "Contains"
        case .pattern: return "Pattern"
        }
    }
    var placeholder: String {
        switch self {
        case .domain: return "github.com or github.com/team"
        case .contains: return "project=my-project"
        case .pattern: return "console.cloud.google.com/*project=my-project*"
        }
    }
    var help: String {
        switch self {
        case .domain: return "Includes subdomains. An optional path narrows the match."
        case .contains: return "Matches text anywhere in the link."
        case .pattern: return "Use * as a wildcard. Matched against the whole link without http(s)://."
        }
    }
}

struct LinkRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var enabled = true
    var kind = LinkRuleKind.domain
    var pattern = ""
    var target = ""
    /// Preserve distinct references even when two aliases currently share a profile.
    var destinationAlias: String?

    /// Matching is case-insensitive. Domains match themselves and their
    /// subdomains, never a lookalike suffix.
    func matches(_ url: URL) -> Bool {
        guard enabled else { return false }
        let value = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        switch kind {
        case .domain:
            var spec = Self.strippingScheme(value).lowercased()
            var path = ""
            if let slash = spec.firstIndex(of: "/") { path = String(spec[slash...]); spec = String(spec[..<slash]) }
            let domain = spec.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let host = (url.host ?? "").lowercased()
            guard !domain.isEmpty, host == domain || host.hasSuffix("." + domain) else { return false }
            // A path narrows at segment boundaries: /team matches /team/x, not /teammate.
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            let target = url.path.lowercased()
            return trimmed.isEmpty || target == trimmed || target.hasPrefix(trimmed + "/")
        case .contains:
            return url.absoluteString.range(of: value, options: .caseInsensitive) != nil
        case .pattern:
            return Self.wildcard(Self.strippingScheme(value), matches: Self.strippingScheme(url.absoluteString))
        }
    }

    var domainLooksInvalid: Bool { kind == .domain && pattern.contains("*") }

    static func strippingScheme(_ value: String) -> String {
        for scheme in ["https://", "http://"] where value.lowercased().hasPrefix(scheme) { return String(value.dropFirst(scheme.count)) }
        return value
    }

    /// `*` matches any run of characters; everything else is literal. Anchored at both ends.
    static func wildcard(_ pattern: String, matches text: String) -> Bool {
        let expression = "^" + pattern.components(separatedBy: "*").map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*") + "$"
        guard let regex = try? NSRegularExpression(pattern: expression, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// A browser profile added by hand, for browsers whose profile list macOS
/// won't let other apps read. `directory` is the profile folder, e.g. "Profile 1".
struct LinkProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var browser: String
    var directory: String
    var name: String
    var destinationID: String { "\(browser):\(directory)" }
}

struct LinkRoutingConfig: Codable, Equatable {
    static let defaultFallback = "com.apple.Safari"
    var rules: [LinkRule] = []
    var fallback = LinkRoutingConfig.defaultFallback
    var profiles: [LinkProfile] = []
    var aliases: [String: String] = [:]

    init(rules: [LinkRule] = [], fallback: String = LinkRoutingConfig.defaultFallback, profiles: [LinkProfile] = []) {
        self.rules = rules; self.fallback = fallback; self.profiles = profiles
    }
    private enum CodingKeys: String, CodingKey { case rules, fallback, profiles, aliases }
    // Fields added later decode as defaults so earlier saved rules still load.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rules = try values.decodeIfPresent([LinkRule].self, forKey: .rules) ?? []
        fallback = try values.decodeIfPresent(String.self, forKey: .fallback) ?? Self.defaultFallback
        profiles = try values.decodeIfPresent([LinkProfile].self, forKey: .profiles) ?? []
        aliases = try values.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
    }

    /// First enabled matching rule wins. Rules are skipped while the feature is off.
    func targetID(for url: URL, applyRules: Bool) -> String {
        guard applyRules else { return fallback }
        return rules.first { $0.matches(url) }?.target ?? fallback
    }

    mutating func move(_ id: UUID, by offset: Int) {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(index + offset) else { return }
        rules.swapAt(index, index + offset)
    }
}

/// A browser, or a Chromium profile within one. Profile IDs are `bundleID:directory`.
struct LinkDestination: Identifiable, Hashable {
    var id: String
    var name: String
    var appPath: String
    var profile: String?

    var bundleID: String { profile == nil ? id : String(id.prefix { $0 != ":" }) }

    /// Profile directories are passed to browsers; reject anything path-like.
    static func validProfileDirectory(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains(":")
    }

    static func splitProfileID(_ id: String) -> (bundleID: String, directory: String)? {
        guard let separator = id.firstIndex(of: ":") else { return nil }
        let directory = String(id[id.index(after: separator)...])
        guard validProfileDirectory(directory) else { return nil }
        return (String(id[..<separator]), directory)
    }
}

enum LinkURL {
    /// Only absolute http(s) links with a host are routed.
    static func parse(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { return nil }
        return url
    }
}
