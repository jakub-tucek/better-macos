import AppKit

private final class FakeLinkBackend: LinkBrowserBackend {
    var found: [LinkDestination] = []
    var opened: [(url: String, destination: String)] = []
    var openError: Error?
    var isDefault = false
    var defaultRequests = 0
    var unreadable: [String] = []
    func discover() -> LinkDiscovery {
        LinkDiscovery(destinations: found, profileBrowsers: found.filter { $0.id == "com.google.Chrome" }.map(\.id), unreadableProfiles: unreadable)
    }
    func systemFallback() -> LinkDestination? { LinkDestination(id: "com.apple.Safari", name: "Safari", appPath: "/Applications/Safari.app") }
    func open(_ url: URL, in destination: LinkDestination, completion: @escaping (Error?) -> Void) {
        opened.append((url.absoluteString, destination.id)); completion(openError)
    }
    var accessRequests: [String] = []
    var grantAccess = false
    func requestProfileAccess(browser: String) -> Bool {
        accessRequests.append(browser)
        if grantAccess { unreadable.removeAll { $0 == browser } }
        return grantAccess
    }
    func isDefaultBrowser() -> Bool { isDefault }
    func makeDefaultBrowser(completion: @escaping (Error?) -> Void) { defaultRequests += 1; isDefault = true; completion(nil) }
}

func runLinksTests() {
    runLinkMatchingTests()
    runLinkOwnerTests()
}

private func url(_ string: String) -> URL { URL(string: string)! }

private func runLinkMatchingTests() {
    let domain = LinkRule(pattern: "example.com")
    expect(domain.matches(url("https://example.com/a")) && domain.matches(url("https://sub.EXAMPLE.com")), "domain rules match the domain and its subdomains")
    expect(!domain.matches(url("https://evilexample.com")) && !domain.matches(url("https://example.com.evil.org")), "domain rules reject lookalike prefixes and suffixes")
    expect(!LinkRule(pattern: "").matches(url("https://example.com")) && !LinkRule(enabled: false, pattern: "example.com").matches(url("https://example.com")),
           "empty and disabled rules never match")
    let team = LinkRule(pattern: "github.com/MyTeam")
    expect(team.matches(url("https://github.com/myteam/repo")) && team.matches(url("https://github.com/MyTeam")),
           "a domain path narrows the match case-insensitively")
    expect(!team.matches(url("https://github.com/MyTeammate")) && !team.matches(url("https://github.com/other")),
           "a domain path matches only at segment boundaries")
    expect(LinkRule(pattern: "https://github.com/MyTeam/").matches(url("https://github.com/MyTeam/x")), "a domain rule tolerates a pasted scheme and trailing slash")
    let contains = LinkRule(kind: .contains, pattern: "127.0.0.1:4312")
    expect(contains.matches(url("http://127.0.0.1:4312/x")) && !contains.matches(url("http://127.0.0.1:4313/")), "contains rules match text anywhere in the link")
    let cloud = LinkRule(kind: .pattern, pattern: "console.cloud.google.com/*project=bf-production*")
    expect(cloud.matches(url("https://console.cloud.google.com/monitoring/alerting?channelType=slack&project=bf-production")),
           "wildcard patterns cover query-parameter routing without a provider-specific rule")
    expect(!cloud.matches(url("https://console.cloud.google.com/monitoring?project=another")) && !cloud.matches(url("https://example.com/?project=bf-production")),
           "wildcard patterns are anchored and reject other projects or hosts")
    expect(LinkRule(kind: .pattern, pattern: "example.com/work/*").matches(url("http://example.com/work/a"))
           && !LinkRule(kind: .pattern, pattern: "example.com/work/*").matches(url("https://example.com/personal")),
           "wildcard patterns replace prefix rules and ignore the scheme")
    expect(LinkRule(kind: .pattern, pattern: "a.com/(x)+?").matches(url("https://a.com/(x)+?")) == true,
           "pattern text other than * is literal, not a regular expression")
    expect(LinkRule(pattern: "*.example.com").domainLooksInvalid && !LinkRule(pattern: "example.com/x").domainLooksInvalid, "only wildcard domains are flagged")
    expect(LinkURL.parse(" https://a.com ") != nil && LinkURL.parse("file:///etc/hosts") == nil && LinkURL.parse("https://") == nil,
           "only absolute http(s) links with a host are routed")
    expect(LinkDestination.splitProfileID("com.google.Chrome:Profile 1")?.directory == "Profile 1"
           && LinkDestination.splitProfileID("com.google.Chrome:../x") == nil && LinkDestination.splitProfileID("com.google.Chrome:..") == nil,
           "profile IDs reject path-like directories")

    var config = LinkRoutingConfig(rules: [LinkRule(pattern: "a.com", target: "first"), LinkRule(pattern: "a.com", target: "second")], fallback: "fallback")
    expect(config.targetID(for: url("https://a.com"), applyRules: true) == "first", "the first matching rule wins")
    expect(config.targetID(for: url("https://a.com"), applyRules: false) == "fallback", "rules are skipped when the feature is off")
    config.move(config.rules[1].id, by: -1)
    expect(config.rules.map(\.target) == ["second", "first"], "rules reorder")
    config.move(config.rules[0].id, by: -1)
    expect(config.rules.map(\.target) == ["second", "first"], "reordering stops at the ends")
}

private func runLinkOwnerTests() {
    let suite = "better-macos.links-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let backend = FakeLinkBackend()
    backend.found = [LinkDestination(id: "com.apple.Safari", name: "Safari", appPath: "/S"),
                     LinkDestination(id: "com.google.Chrome", name: "Chrome", appPath: "/C"),
                     LinkDestination(id: "com.google.Chrome:Default", name: "Chrome · Work", appPath: "/C", profile: "Default")]
    let owner = LinksModule(defaults: defaults, backend: backend)
    expect(owner.config == LinkRoutingConfig() && owner.destinations.isEmpty, "a fresh owner starts with no rules and does not discover browsers until needed")

    owner.update { $0.rules = [LinkRule(pattern: "work.com", target: "com.google.Chrome:Default")] }
    owner.route(url("https://work.com/x"))
    expect(backend.opened.last?.destination == "com.apple.Safari", "an inactive feature passes links to the fallback")
    owner.setActive(true)
    owner.route(url("https://work.com/x"))
    expect(backend.opened.last?.destination == "com.google.Chrome:Default", "an active feature routes matching links to a profile")
    owner.route(url("https://other.com"))
    expect(backend.opened.last?.destination == "com.apple.Safari", "unmatched links open in the fallback")

    owner.update { $0.rules = [LinkRule(pattern: "work.com", target: "com.google.Chrome:Profile 3")] }
    owner.refresh()
    expect(owner.destinations.contains { $0.id == "com.google.Chrome:Profile 3" && $0.profile == "Profile 3" },
           "a saved profile stays routable when the browser hides its profile list")
    owner.update { $0.rules[0].target = "org.gone.Browser"; $0.fallback = "org.gone.Fallback" }
    let before = backend.opened.count
    owner.route(url("https://work.com"))
    expect(backend.opened.count == before + 1 && backend.opened.last?.destination == "com.apple.Safari",
           "an unavailable target and fallback still open the link in the system browser")
    let opened = backend.opened.count
    owner.route(url("ftp://work.com"))
    expect(backend.opened.count == opened, "non-web links are not opened")

    backend.unreadable = ["com.google.Chrome"]
    backend.found.removeAll { $0.profile != nil }
    owner.refresh()
    expect(owner.profilesUnreadable && owner.profileBrowsers.map(\.id) == ["com.google.Chrome"], "a blocked profile list is reported for profile-capable browsers")
    expect(!owner.addProfile(browser: "com.google.Chrome", directory: "../x", name: "Bad") && !owner.addProfile(browser: "org.unknown", directory: "Profile 1", name: "X"),
           "hand-added profiles reject path-like folders and unknown browsers")
    expect(owner.addProfile(browser: "com.google.Chrome", directory: " Profile 1 ", name: "Work"), "a profile can be added by folder name")
    expect(owner.destinations.contains { $0.id == "com.google.Chrome:Profile 1" && $0.name == "Chrome · Work" && $0.profile == "Profile 1" },
           "hand-added profiles appear in pickers under their chosen name")
    owner.update { $0.rules = [LinkRule(pattern: "work.com", target: "com.google.Chrome:Profile 1")]; $0.fallback = "com.apple.Safari" }
    owner.route(url("https://work.com/a"))
    expect(backend.opened.last?.destination == "com.google.Chrome:Profile 1", "rules route to hand-added profiles")
    owner.addProfile(browser: "com.google.Chrome", directory: "Profile 1", name: "Job")
    expect(owner.config.profiles.count == 1 && owner.config.profiles[0].name == "Job", "re-adding a folder renames instead of duplicating")
    owner.removeProfile(owner.config.profiles[0].id)
    expect(owner.config.profiles.isEmpty && owner.destinations.contains { $0.id == "com.google.Chrome:Profile 1" },
           "removing a profile keeps rules that use it routable by folder name")
    let chrome = owner.unreadableProfileBrowsers[0]
    owner.requestProfileAccess(chrome)
    expect(backend.accessRequests == ["com.google.Chrome"] && owner.profilesUnreadable && owner.profileAccessResult == .notChosen(browser: "Chrome"),
           "a canceled folder choice keeps the profile list blocked and says so")
    backend.grantAccess = true
    backend.found.append(LinkDestination(id: "com.google.Chrome:Profile 2", name: "Chrome · Personal", appPath: "/C", profile: "Profile 2"))
    owner.requestProfileAccess(chrome)
    expect(!owner.profilesUnreadable && owner.destinations.contains { $0.id == "com.google.Chrome:Profile 2" }
           && owner.profileAccessResult == .granted(browser: "Chrome", count: 1) && owner.foundProfiles.map(\.id) == ["com.google.Chrome:Profile 2"],
           "granting folder access re-reads and lists discovered profiles")
    let legacy = try? JSONDecoder().decode(LinkRoutingConfig.self, from: Data(#"{"rules":[],"fallback":"x"}"#.utf8))
    expect(legacy?.fallback == "x" && legacy?.profiles.isEmpty == true, "rules saved before profiles existed still load")

    let reloaded = LinksModule(defaults: defaults, backend: backend)
    expect(reloaded.config == owner.config, "rules persist in the injected preferences")

    owner.acceptsActions = { false }
    let blockedCount = backend.opened.count
    let frozen = owner.config
    owner.update { $0.rules = [] }
    owner.makeDefaultBrowser()
    owner.testOpen("https://work.com")
    expect(owner.config == frozen && backend.defaultRequests == 0 && backend.opened.count == blockedCount,
           "settings edits, default-browser changes and test opens obey host admission")
    owner.route(url("https://work.com"))
    expect(backend.opened.count == blockedCount + 1, "incoming links are still delivered while the host is closed")
    owner.setActive(false)

    defaults.set(Data("not json".utf8), forKey: LinksModule.configKey)
    let unreadable = LinksModule(defaults: defaults, backend: backend)
    expect(unreadable.config.rules.isEmpty && defaults.data(forKey: LinksModule.configKey + ".unreadable") == Data("not json".utf8),
           "unreadable rules are preserved as a backup instead of being silently overwritten")
}
