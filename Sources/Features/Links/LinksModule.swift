import AppKit

/// OS boundary for browser discovery and hand-off. Tests inject a fake so they
/// never change the default browser or open links.
protocol LinkBrowserBackend {
    /// Browsers and readable Chromium profiles, excluding this app.
    func discover() -> LinkDiscovery
    /// A browser that always exists, used when no saved destination resolves.
    func systemFallback() -> LinkDestination?
    func open(_ url: URL, in destination: LinkDestination, completion: @escaping (Error?) -> Void)
    /// Asks the person to pick the browser's profile folder. Choosing it is the
    /// consent macOS records for that folder only. Returns false if canceled or
    /// a different folder was chosen.
    func requestProfileAccess(browser: String) -> Bool
    func isDefaultBrowser() -> Bool
    func makeDefaultBrowser(completion: @escaping (Error?) -> Void)
    /// Replace only web schemes still owned by this app; preserve external changes.
    func relinquishDefaultBrowser(to destination: LinkDestination, completion: @escaping (Error?) -> Void)
}

enum LinkProfileAccessResult: Equatable {
    case granted(browser: String, count: Int)
    case blocked(browser: String)
    case notChosen(browser: String)
}

struct LinkDiscovery {
    var destinations: [LinkDestination] = []
    /// Installed browsers that support profiles (bundle IDs).
    var profileBrowsers: [String] = []
    /// Profile browsers whose profile list macOS refused to let us read.
    var unreadableProfiles: [String] = []
}

/// Routes http(s) links to a browser or browser profile. The owner always exists
/// so links keep reaching the fallback while the feature is off or the app quits;
/// only rule matching and the responsiveness activity follow the enable choice.
final class LinksModule: ObservableObject {
    static let configKey = "links.config"
    @Published private(set) var config = LinkRoutingConfig()
    @Published private(set) var destinations: [LinkDestination] = []
    @Published private(set) var isDefaultBrowser = false
    @Published private(set) var message = ""
    @Published private(set) var active = false
    @Published private(set) var changingDefaultBrowser = false
    /// Installed browsers that support profiles, for adding a profile by hand.
    @Published private(set) var profileBrowsers: [LinkDestination] = []
    /// Profile browsers whose profile list macOS blocked; access can be requested.
    @Published private(set) var unreadableProfileBrowsers: [LinkDestination] = []
    var profilesUnreadable: Bool { !unreadableProfileBrowsers.isEmpty }
    /// Profiles read from browsers, as opposed to added by hand.
    @Published private(set) var foundProfiles: [LinkDestination] = []
    @Published private(set) var profileAccessResult: LinkProfileAccessResult?
    var acceptsActions: () -> Bool = { true }
    private let defaults: UserDefaults
    private let backend: LinkBrowserBackend
    private var discovered = false
    private var routingActivity: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, backend: LinkBrowserBackend = SystemLinkBrowserBackend()) {
        self.defaults = defaults
        self.backend = backend
        if let data = defaults.data(forKey: Self.configKey) {
            do { config = try JSONDecoder().decode(LinkRoutingConfig.self, from: data) }
            catch {
                // Keep unreadable rules for manual recovery instead of overwriting them.
                defaults.set(data, forKey: Self.configKey + ".unreadable")
                message = "Saved link rules could not be read; they were kept as a backup."
            }
        }
    }

    /// Rules apply only while active. A resident router must answer promptly with
    /// no visible window, so App Nap is held off without blocking idle sleep.
    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if value {
            routingActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Respond promptly to opened links")
        } else if let routingActivity {
            ProcessInfo.processInfo.endActivity(routingActivity)
            self.routingActivity = nil
        }
    }

    func refresh() {
        discovered = true
        let discovery = backend.discover()
        var found = discovery.destinations
        func browser(_ id: String) -> LinkDestination? { found.first { $0.id == id && $0.profile == nil } }
        profileBrowsers = discovery.profileBrowsers.compactMap(browser)
        unreadableProfileBrowsers = discovery.unreadableProfiles.compactMap(browser)
        foundProfiles = discovery.destinations.filter { $0.profile != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // macOS can refuse reading a browser's profile list. Hand-added profiles,
        // and any profile ID a rule already uses, still route when the browser exists.
        for profile in config.profiles where LinkDestination.validProfileDirectory(profile.directory) {
            guard let app = browser(profile.browser) else { continue }
            found.removeAll { $0.id == profile.destinationID }
            found.append(LinkDestination(id: profile.destinationID, name: "\(app.name) · \(profile.name)", appPath: app.appPath, profile: profile.directory))
        }
        for id in Set(config.rules.map(\.target) + [config.fallback]) where !found.contains(where: { $0.id == id }) {
            guard let (bundleID, directory) = LinkDestination.splitProfileID(id), let app = browser(bundleID) else { continue }
            found.append(LinkDestination(id: id, name: "\(app.name) · \(directory)", appPath: app.appPath, profile: directory))
        }
        destinations = Array(Set(found)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        isDefaultBrowser = backend.isDefaultBrowser()
    }

    func destination(for url: URL) -> LinkDestination? {
        if !discovered { refresh() }
        let id = config.targetID(for: url, applyRules: active)
        return destinations.first { $0.id == id }
    }

    @discardableResult
    func saveRuleText(_ text: String, expected: [LinkRule]) -> Bool {
        guard acceptsActions(), config.rules == expected else { return false }
        let parsed = LinkRuleText.parse(text, destinations: destinations, existing: config.rules)
        guard parsed.errors.isEmpty else { return false }
        update { $0.rules = parsed.rules }
        return config.rules == parsed.rules
    }

    /// Presentation reads only the current snapshot; typing never discovers or opens a browser.
    func preview(for url: URL) -> String {
        let target = config.targetID(for: url, applyRules: active)
        if let destination = destinations.first(where: { $0.id == target }) { return "Would open in \(destination.name)" }
        if let fallback = destinations.first(where: { $0.id == config.fallback }) { return "Chosen browser unavailable · would use \(fallback.name)" }
        return "Chosen browser unavailable · will try Safari"
    }

    /// Incoming links are never dropped: an unavailable target falls back to the
    /// saved fallback, then to the system browser. Not gated by host admission.
    func route(_ url: URL) {
        guard LinkURL.parse(url.absoluteString) != nil else { message = "Only http and https links are supported."; return }
        let started = Diagnostics.shared.start()
        let preferred = destination(for: url)
        guard let destination = preferred ?? destinations.first(where: { $0.id == config.fallback }) ?? backend.systemFallback() else {
            message = "No browser is available to open links."; return
        }
        let rules = active
        backend.open(url, in: destination) { [weak self] error in
            DispatchQueue.main.async {
                Diagnostics.shared.emit("links", "routed", outcome: error == nil ? "success" : "failure", since: started,
                                        fields: ["profile": destination.profile == nil ? "false" : "true", "rules": rules ? "applied" : "skipped"])
                if let error { self?.message = "Could not open in \(destination.name): \(error.localizedDescription)" }
                else { self?.message = preferred == nil ? "Chosen browser unavailable. Opened in \(destination.name) instead." : "Opened in \(destination.name)." }
            }
        }
    }

    /// Settings edits are user actions and recheck host admission.
    func update(_ change: (inout LinkRoutingConfig) -> Void) {
        guard acceptsActions() else { return }
        var value = config
        change(&value)
        guard value != config else { return }
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: Self.configKey)
            config = value
        } catch { message = "Could not save link rules: \(error.localizedDescription)" }
    }

    /// Returns false for an invalid folder name or an unknown browser.
    @discardableResult
    func addProfile(browser: String, directory: String, name: String) -> Bool {
        let folder = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard acceptsActions(), LinkDestination.validProfileDirectory(folder), profileBrowsers.contains(where: { $0.id == browser }) else { return false }
        update { config in
            config.profiles.removeAll { $0.browser == browser && $0.directory == folder }
            config.profiles.append(LinkProfile(browser: browser, directory: folder, name: label.isEmpty ? folder : label))
        }
        refresh()
        return true
    }

    func removeProfile(_ id: UUID) {
        update { $0.profiles.removeAll { $0.id == id } }
        refresh()
    }

    func requestProfileAccess(_ browser: LinkDestination) {
        guard acceptsActions() else { return }
        let result: LinkProfileAccessResult
        if backend.requestProfileAccess(browser: browser.id) {
            refresh()
            result = unreadableProfileBrowsers.contains { $0.id == browser.id } ? .blocked(browser: browser.name)
                : .granted(browser: browser.name, count: foundProfiles.filter { $0.bundleID == browser.id }.count)
        } else { result = .notChosen(browser: browser.name) }
        profileAccessResult = result
        let outcome: String, count: Int
        switch result {
        case .granted(_, let found): outcome = "success"; count = found
        case .blocked: outcome = "blocked"; count = 0
        case .notChosen: outcome = "canceled"; count = 0
        }
        Diagnostics.shared.emit("links", "profile_access", outcome: outcome, fields: ["profiles": String(count)])
    }

    func testOpen(_ string: String) {
        guard acceptsActions(), let url = LinkURL.parse(string) else { return }
        route(url)
    }

    func makeDefaultBrowser() {
        guard acceptsActions(), active, !changingDefaultBrowser else { return }
        changingDefaultBrowser = true
        backend.makeDefaultBrowser { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                changingDefaultBrowser = false
                isDefaultBrowser = backend.isDefaultBrowser()
                message = error.map { "Default browser was not changed: \($0.localizedDescription)" }
                    ?? "Better macOS now receives web links."
            }
        }
    }

    /// Explicit disable only. Quit leaves the browser association intact.
    func prepareDisable(completion: @escaping (Result<Void, ModuleChoiceFailure>) -> Void) {
        guard acceptsActions(), !changingDefaultBrowser else {
            completion(.failure(ModuleChoiceFailure(detail: "Browser change is busy.", message: "Wait for the browser change to finish, then retry.")))
            return
        }
        guard backend.isDefaultBrowser() else { isDefaultBrowser = false; completion(.success(())); return }
        refresh()
        let browserID = LinkDestination.splitProfileID(config.fallback)?.bundleID ?? config.fallback
        guard let browser = destinations.first(where: { $0.id == browserID && $0.profile == nil }) ?? backend.systemFallback() else {
            completion(.failure(ModuleChoiceFailure(detail: "No fallback browser available.", message: "Choose an installed fallback browser before turning Links off.")))
            return
        }
        changingDefaultBrowser = true
        var completed = false
        backend.relinquishDefaultBrowser(to: browser) { [self] error in
            DispatchQueue.main.async { [self] in
                guard !completed else { return }
                completed = true
                changingDefaultBrowser = false
                isDefaultBrowser = backend.isDefaultBrowser()
                if let error {
                    message = "Links could not be turned off: \(error.localizedDescription)"
                    completion(.failure(ModuleChoiceFailure(detail: message, message: message)))
                } else if isDefaultBrowser {
                    message = "Better macOS still receives web links. Retry turning Links off or change the default browser in System Settings."
                    completion(.failure(ModuleChoiceFailure(detail: message, message: message)))
                } else {
                    message = "Links is off. Web links were handed back to \(browser.name)."
                    completion(.success(()))
                }
            }
        }
    }
}

struct SystemLinkBrowserBackend: LinkBrowserBackend {
    private static let chromiumRoots = ["com.google.Chrome": "Google/Chrome", "com.microsoft.edgemac": "Microsoft Edge",
                                        "com.brave.Browser": "BraveSoftware/Brave-Browser", "com.vivaldi.Vivaldi": "Vivaldi",
                                        "org.chromium.Chromium": "Chromium"]
    private static let probe = URL(string: "https://example.com")!
    private static let shortcutPrefix = "BetterMacOS-Link-"

    init() { Self.removeStaleShortcuts() }

    func discover() -> LinkDiscovery {
        var result = LinkDiscovery()
        var found: [LinkDestination] = []
        var seen = Set<String>()
        for candidate in NSWorkspace.shared.urlsForApplications(toOpen: Self.probe) {
            guard let id = Bundle(url: candidate)?.bundleIdentifier, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { continue }
            // Prefer the copy Launch Services would open for this identifier.
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) ?? candidate
            let bundle = Bundle(url: app)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? app.deletingPathExtension().lastPathComponent
            found.append(LinkDestination(id: id, name: name, appPath: app.path))
            guard let root = Self.chromiumRoots[id] else { continue }
            result.profileBrowsers.append(id)
            let state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(root)/Local State")
            // macOS protects other apps' data; without Full Disk Access this read fails.
            guard let data = try? Data(contentsOf: state) else { result.unreadableProfiles.append(id); continue }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] else { continue }
            for (directory, info) in cache where LinkDestination.validProfileDirectory(directory) {
                found.append(LinkDestination(id: "\(id):\(directory)", name: "\(name) · \(info["name"] as? String ?? directory)",
                                             appPath: app.path, profile: directory))
            }
        }
        result.destinations = found
        return result
    }

    func systemFallback() -> LinkDestination? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: LinkRoutingConfig.defaultFallback)
            .map { LinkDestination(id: LinkRoutingConfig.defaultFallback, name: "Safari", appPath: $0.path) }
    }

    func open(_ url: URL, in destination: LinkDestination, completion: @escaping (Error?) -> Void) {
        let app = URL(fileURLWithPath: destination.appPath)
        guard let profile = destination.profile else {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in completion(error) }
            return
        }
        guard LinkDestination.validProfileDirectory(profile) else { completion(ToggleError(message: "Invalid browser profile.")); return }
        if destination.bundleID == "com.google.Chrome" {
            // A .crwebloc reaches an already-running Chrome directly; launching its
            // executable instead can take seconds to forward the request.
            let shortcut = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.shortcutPrefix)\(UUID().uuidString).crwebloc")
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString, "CrProfile": profile], format: .xml, options: 0)
                try data.write(to: shortcut, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: shortcut.path)
            } catch { try? FileManager.default.removeItem(at: shortcut); completion(error); return }
            NSWorkspace.shared.open([shortcut], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                DispatchQueue.global().asyncAfter(deadline: .now() + 120) { try? FileManager.default.removeItem(at: shortcut) }
                completion(error)
            }
            return
        }
        guard let executable = Bundle(url: app)?.executableURL else { completion(ToggleError(message: "Browser executable is unavailable.")); return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--profile-directory=\(profile)", url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); completion(nil) } catch { completion(error) }
    }

    func requestProfileAccess(browser: String) -> Bool {
        guard let root = Self.chromiumRoots[browser] else { return false }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(root)", isDirectory: true)
        let panel = NSOpenPanel()
        panel.message = "Select the “\(folder.lastPathComponent)” folder and choose Allow so Better macOS can read its profile list."
        panel.prompt = "Allow"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = folder.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        return chosen.standardizedFileURL.resolvingSymlinksInPath().path == folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func isDefaultBrowser() -> Bool {
        ["http", "https"].contains { ownsScheme($0) }
    }

    private func ownsScheme(_ scheme: String) -> Bool {
        guard let probe = URL(string: "\(scheme)://example.com"),
              let current = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return Bundle(url: current)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    func relinquishDefaultBrowser(to destination: LinkDestination, completion: @escaping (Error?) -> Void) {
        let app = URL(fileURLWithPath: destination.appPath)
        guard let id = Bundle(url: app)?.bundleIdentifier, id != Bundle.main.bundleIdentifier else {
            completion(ToggleError(message: "Fallback browser is unavailable.")); return
        }
        func restore(_ schemes: ArraySlice<String>) {
            guard let scheme = schemes.first else { completion(nil); return }
            guard ownsScheme(scheme) else { restore(schemes.dropFirst()); return }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { error in
                DispatchQueue.main.async {
                    if let error { completion(error) }
                    else { restore(schemes.dropFirst()) }
                }
            }
        }
        restore(["http", "https"][...])
    }

    func makeDefaultBrowser(completion: @escaping (Error?) -> Void) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            guard error == nil else { completion(error); return }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https", completion: completion)
        }
    }

    private static func removeStaleShortcuts() {
        let folder = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix(shortcutPrefix) && file.pathExtension == "crwebloc" {
            guard let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  created < Date().addingTimeInterval(-600) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
