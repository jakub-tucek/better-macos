import AppKit

enum SourceUpdateComparison {
    case current
    case available(String)
    case diverged

    static func parse(_ data: Data, headRevision: String) throws -> SourceUpdateComparison {
        struct Comparison: Decodable {
            let status: String
        }
        let result = try JSONDecoder().decode(Comparison.self, from: data)
        guard isRevision(headRevision) else { throw ToggleError(message: "Invalid update revision.") }
        switch result.status {
        case "ahead": return .available(headRevision)
        case "identical", "behind": return .current
        case "diverged": return .diverged
        default: throw ToggleError(message: "Unrecognized update response.")
        }
    }

    static func isRevision(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct SourceInstallation {
    let revision: String
    let sourceDirectory: String?
    let destination: String?
    let localDevelopment: Bool
    var managed: Bool { sourceDirectory != nil && destination != nil }

    init(revision: String, sourceDirectory: String? = nil, destination: String? = nil, localDevelopment: Bool = false) {
        self.revision = revision
        self.sourceDirectory = sourceDirectory
        self.destination = destination
        self.localDevelopment = localDevelopment
    }

    init(bundle: Bundle = .main) {
        revision = bundle.object(forInfoDictionaryKey: "BetterMacOSRevision") as? String ?? ""
        let managed = bundle.object(forInfoDictionaryKey: "BetterMacOSSourceInstall") as? Bool == true
        sourceDirectory = managed ? bundle.object(forInfoDictionaryKey: "BetterMacOSSourceDirectory") as? String : nil
        destination = managed ? bundle.object(forInfoDictionaryKey: "BetterMacOSInstallDestination") as? String : nil
        localDevelopment = managed && bundle.object(forInfoDictionaryKey: "BetterMacOSLocalDevelopment") as? Bool == true
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func updateScript(revision: String) throws -> String {
        guard SourceUpdateComparison.isRevision(revision), let sourceDirectory, let destination,
              sourceDirectory.hasPrefix("/"), destination.hasPrefix("/") else {
            throw ToggleError(message: "Install this app using install.sh before updating it here.")
        }
        let state = URL(fileURLWithPath: sourceDirectory).deletingLastPathComponent().path
        let appDirectory = URL(fileURLWithPath: destination).deletingLastPathComponent().path
        if localDevelopment {
            return """
            #!/bin/bash
            set -euo pipefail
            exec /usr/bin/env python3 \(Self.shellQuote(sourceDirectory + "/scripts/deploy.py")) --source \(Self.shellQuote(sourceDirectory)) --destination \(Self.shellQuote(destination)) --update --revision \(Self.shellQuote(revision))
            """ + "\n"
        }
        return """
        #!/bin/bash
        set -euo pipefail
        export BETTER_MACOS_HOME=\(Self.shellQuote(state))
        export BETTER_MACOS_APP_DIR=\(Self.shellQuote(appDirectory))
        export BETTER_MACOS_REVISION=\(Self.shellQuote(revision))
        /usr/bin/curl --fail --silent --show-error --location --proto '=https' \\
          'https://raw.githubusercontent.com/jakub-tucek/better-macos/\(revision)/install.sh' | /bin/bash
        """ + "\n"
    }
}

/// Only checks source history automatically. Installation requires a user action
/// and runs in Terminal so it survives the old app's graceful shutdown.
final class SourceUpdater {
    private let installation: SourceInstallation
    private let defaults: UserDefaults
    private let session: URLSession
    private var timer: Timer?
    private var task: URLSessionDataTask?
    private(set) var status = "Not checked yet"
    private(set) var isChecking = false
    private(set) var availableRevision: String?
    var canInstall: Bool { installation.managed && availableRevision != nil }
    var onChange: (() -> Void)?

    init(installation: SourceInstallation = SourceInstallation(), defaults: UserDefaults = .standard,
         session: URLSession = .shared) {
        self.installation = installation
        self.defaults = defaults
        self.session = session
    }

    func start() {
        check()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil; task?.cancel(); task = nil }

    func check(force: Bool = false) {
        guard !isChecking else { return }
        guard SourceUpdateComparison.isRevision(installation.revision) else {
            status = "Build has no source revision"; onChange?(); return
        }
        let cacheKey = "updates.\(installation.revision)"
        if !force, let checked = defaults.object(forKey: cacheKey + ".checked") as? Date,
           Date().timeIntervalSince(checked) < 24 * 3600 {
            if let data = defaults.data(forKey: cacheKey + ".comparison"),
               let head = defaults.string(forKey: cacheKey + ".head"),
               let comparison = try? SourceUpdateComparison.parse(data, headRevision: head) {
                apply(comparison)
            } else { status = "Next automatic check within 24 hours"; onChange?() }
            return
        }
        // Comparing history, rather than SHA inequality, avoids offering a
        // downgrade when a developer build is ahead of published main.
        defaults.set(Date(), forKey: cacheKey + ".checked")
        isChecking = true
        status = "Checking source changes…"
        onChange?()
        fetch("https://api.github.com/repos/jakub-tucek/better-macos/commits/main") { [weak self] result in
            guard let self else { return }
            do {
                struct Commit: Decodable { let sha: String }
                let head = try JSONDecoder().decode(Commit.self, from: result.get()).sha
                guard SourceUpdateComparison.isRevision(head) else { throw ToggleError(message: "Invalid update revision.") }
                // Pin both requests to the same head, even if main moves during the check.
                fetch("https://api.github.com/repos/jakub-tucek/better-macos/compare/\(installation.revision)...\(head)?per_page=1") { [weak self] result in
                    guard let self else { return }
                    do {
                        let data = try result.get()
                        let comparison = try SourceUpdateComparison.parse(data, headRevision: head)
                        defaults.set(data, forKey: cacheKey + ".comparison")
                        defaults.set(head, forKey: cacheKey + ".head")
                        isChecking = false
                        apply(comparison)
                    } catch { failed(error) }
                }
            } catch { failed(error) }
        }
    }

    private func failed(_ error: Error) {
        isChecking = false
        availableRevision = nil
        status = error.localizedDescription
        onChange?()
    }

    private func fetch(_ url: String, completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Better-macOS-source-updater", forHTTPHeaderField: "User-Agent")
        task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.task = nil
                guard error == nil, let response = response as? HTTPURLResponse, response.statusCode == 200, let data else {
                    let message = (response as? HTTPURLResponse)?.statusCode == 404 ? "This build's revision is not published" : "Update check failed — try again later"
                    completion(.failure(ToggleError(message: message)))
                    return
                }
                completion(.success(data))
            }
        }
        task?.resume()
    }

    private func apply(_ comparison: SourceUpdateComparison) {
        availableRevision = nil
        switch comparison {
        case .current: status = "Up to date · \(installation.revision.prefix(7))"
        case .available(let revision):
            availableRevision = revision
            status = "Source update available · \(revision.prefix(7))"
        case .diverged: status = "Source histories differ — check your checkout"
        }
        onChange?()
    }

    func install() throws {
        guard let revision = availableRevision else { return }
        let script = try installation.updateScript(revision: revision)
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Better macOS")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Update Better macOS.command")
        try Data(script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: .init()) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.status = error.localizedDescription; self?.onChange?() } }
        }
    }
}
