import Foundation

func runLinkRuleTextTests() {
    let destinations = [LinkDestination(id: "safari", name: "Safari", appPath: "/S"), LinkDestination(id: "chrome:Profile 1", name: "Chrome · Work", appPath: "/C", profile: "Profile 1")]
    let rules = [LinkRule(pattern: "example.com", target: "safari"),
                 LinkRule(enabled: false, kind: .pattern, pattern: "site/*?q=x", target: "chrome:Profile 1"),
                 LinkRule(kind: .contains, pattern: "text -> with \"quotes\"\nand newline", target: "missing.browser")]
    let parsed = LinkRuleText.parse(LinkRuleText.render(rules), destinations: destinations, existing: rules)
    expect(parsed.errors.isEmpty && parsed.rules == rules, "Text editing round-trips rule IDs, order, disabled state, profiles, unavailable destinations and escaped text")
    let edited = LinkRuleText.parse("github.com -> Safari\r\noff: contains: project=work -> Chrome · Work\npattern: site/* -> safari", destinations: destinations, existing: [])
    expect(edited.errors.isEmpty && edited.rules.map(\.kind) == [.domain, .contains, .pattern] && edited.rules.map(\.target) == ["safari", "chrome:Profile 1", "safari"] && !edited.rules[1].enabled, "Text rules support names, stable IDs, default domain matching and disabled lines")
    let invalid = LinkRuleText.parse("missing separator\nexample.com -> unknown\n\"broken -> Safari", destinations: destinations, existing: [])
    expect(invalid.errors.count == 3, "Text validation identifies every malformed line and unknown target")
    let ambiguous = LinkRuleText.parse("site -> Safari", destinations: destinations + [LinkDestination(id: "other", name: "Safari", appPath: "/O")], existing: [])
    expect(!ambiguous.errors.isEmpty, "Ambiguous browser names require stable IDs")
    expect(LinkRuleText.parse("\n  \n", destinations: destinations, existing: rules).rules.isEmpty, "Blank text explicitly removes all rules")
    expect(LinkRuleText.parse("site → Safari", destinations: destinations, existing: []).errors.isEmpty, "Pasted arrow characters also separate match and destination")
}
