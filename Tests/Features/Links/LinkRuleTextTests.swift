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
    var draft = LinkRulesDraft()
    draft.load(rules)
    expect(draft.mode == .text && !draft.changed, "Text mode starts from saved rules without pending changes")
    draft.select(.visual, destinations: destinations)
    draft.edit { $0[0].pattern = "edited.example"; $0[1].enabled = true }
    expect(draft.changed && draft.select(.text, destinations: destinations) && draft.text.contains("edited.example"), "Switching to Text preserves unsaved visual edits")
    draft.text = "contains: work -> Safari"
    expect(draft.select(.visual, destinations: destinations) && draft.rules.count == 1 && draft.rules[0].kind == .contains && draft.rules[0].pattern == "work", "Switching to Visual uses the current unsaved text")
    let pending = draft.rules
    draft.select(.text, destinations: destinations)
    draft.text = "broken line"
    expect(!draft.select(.visual, destinations: destinations) && draft.mode == .text && draft.text == "broken line" && draft.rules == pending,
           "Invalid text blocks mode switching without discarding the draft")
    draft.load(rules)
    expect(!draft.changed && draft.rules == rules && draft.text == LinkRuleText.render(rules), "Discard reloads the same saved rules in either mode")
    let aliased = LinkRuleText.parse("work.example -> @work\nalias: work -> chrome:Profile 1\nalias: personal -> Safari\noff: contains: private -> @personal", destinations: destinations, existing: [])
    expect(aliased.errors.isEmpty && aliased.rules.map(\.target) == ["chrome:Profile 1", "safari"] && aliased.aliases["work"] == "chrome:Profile 1", "Aliases resolve forward declarations and browser names to stable routing IDs")
    let rendered = LinkRuleText.render(aliased.rules, aliases: aliased.aliases)
    let roundTrip = LinkRuleText.parse(rendered, destinations: [], existing: aliased.rules, existingAliases: aliased.aliases)
    expect(rendered.contains("-> @work") && roundTrip.rules == aliased.rules && roundTrip.aliases == aliased.aliases && roundTrip.errors.isEmpty, "Aliases render compactly and round-trip with unavailable browsers")
    let badAliases = LinkRuleText.parse("alias: work -> Safari\nalias: work -> chrome:Profile 1\nalias: bad name -> Safari\nsite -> @missing\nalias: chained -> @work", destinations: destinations, existing: [])
    expect(badAliases.errors.count == 4, "Duplicate, invalid, undefined and chained aliases fail with line errors")
    expect(!LinkRuleText.parse("alias: Work -> Safari\nsite -> @work", destinations: destinations, existing: []).errors.isEmpty, "Alias lookup is case-sensitive")
    draft.load(aliased.rules, aliases: aliased.aliases)
    expect(!draft.changed && draft.select(.visual, destinations: destinations), "Saved aliases enter Visual without changes")
    draft.edit { $0[0].pattern = "edited.example" }
    expect(draft.select(.text, destinations: destinations) && draft.text.contains("alias: work -> chrome:Profile 1") && draft.text.contains("edited.example -> @work"), "Visual edits preserve alias declarations and compact references")
    draft.text = draft.text.replacingOccurrences(of: "alias: work -> chrome:Profile 1", with: "alias: work -> Safari")
    expect(draft.parsed(destinations: destinations).rules.allSatisfy { $0.target == "safari" }, "Editing one alias redirects all its draft references")
    draft.load(aliased.rules, aliases: aliased.aliases)
    expect(!draft.changed && draft.text == rendered, "Discard restores alias definitions alongside rules")
}
