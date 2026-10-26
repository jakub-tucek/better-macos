import Foundation

struct LinkRulesDraft {
    enum Mode: String, CaseIterable { case visual = "Visual", text = "Text" }
    var mode = Mode.visual
    private(set) var baseline: [LinkRule] = []
    var text = ""
    private(set) var rules: [LinkRule] = []
    var changed: Bool { text != LinkRuleText.render(baseline) }

    mutating func load(_ saved: [LinkRule]) {
        baseline = saved; rules = saved; text = LinkRuleText.render(saved)
    }

    mutating func edit(_ change: (inout [LinkRule]) -> Void) {
        change(&rules)
        text = LinkRuleText.render(rules)
    }

    func parsed(destinations: [LinkDestination]) -> LinkRuleText.Result {
        LinkRuleText.parse(text, destinations: destinations, existing: rules + baseline.filter { original in !rules.contains { $0.id == original.id } })
    }

    @discardableResult
    mutating func select(_ next: Mode, destinations: [LinkDestination]) -> Bool {
        guard next != mode else { return true }
        if next == .visual {
            let result = parsed(destinations: destinations)
            guard result.errors.isEmpty else { return false }
            rules = result.rules
        }
        mode = next
        return true
    }
}
