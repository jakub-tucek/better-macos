import Foundation

struct LinkRulesDraft {
    enum Mode: String, CaseIterable { case visual = "Visual", text = "Text" }
    var mode = Mode.text
    private(set) var baseline: [LinkRule] = []
    var text = ""
    private(set) var rules: [LinkRule] = []
    private(set) var baselineAliases: [String: String] = [:]
    private(set) var aliases: [String: String] = [:]
    var changed: Bool { text != LinkRuleText.render(baseline, aliases: baselineAliases) }

    mutating func load(_ saved: [LinkRule], aliases: [String: String] = [:]) {
        baseline = saved; rules = saved; baselineAliases = aliases; self.aliases = aliases
        text = LinkRuleText.render(saved, aliases: aliases)
    }

    mutating func edit(_ change: (inout [LinkRule]) -> Void) {
        change(&rules)
        text = LinkRuleText.render(rules, aliases: aliases)
    }

    func parsed(destinations: [LinkDestination]) -> LinkRuleText.Result {
        LinkRuleText.parse(text, destinations: destinations, existing: rules + baseline.filter { original in !rules.contains { $0.id == original.id } }, existingAliases: baselineAliases.merging(aliases) { _, current in current })
    }

    @discardableResult
    mutating func select(_ next: Mode, destinations: [LinkDestination]) -> Bool {
        guard next != mode else { return true }
        if next == .visual {
            let result = parsed(destinations: destinations)
            guard result.errors.isEmpty else { return false }
            rules = result.rules
            aliases = result.aliases
        }
        mode = next
        return true
    }
}
