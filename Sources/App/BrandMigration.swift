import Foundation

/// One-time import before feature owners open preferences or recovery files.
/// Legacy names appear only here and in installer upgrade detection.
enum BrandMigration {
    static let oldDomain = "io.github.jakub-tucek.mac-utils"
    static let domain = "io.github.jakub-tucek.better-macos"
    static let marker = "migration.betterMacOS.v1"

    static func run(home: URL, defaults: UserDefaults, oldDomain: String = oldDomain,
                    newDomain: String = domain) throws {
        guard defaults.persistentDomain(forName: newDomain)?[marker] as? Bool != true else { return }
        let manager = FileManager.default
        func move(_ source: URL, _ target: URL) throws {
            guard manager.fileExists(atPath: source.path) else { return }
            if manager.fileExists(atPath: target.path) {
                let from = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let to = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard from.isDirectory == true, to.isDirectory == true,
                      from.isSymbolicLink != true, to.isSymbolicLink != true else {
                    throw NSError(domain: "BrandMigration", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "Existing data at \(target.path) conflicts with migration from \(source.path). Both are preserved; resolve the conflict before starting Better macOS."])
                }
                for child in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                    try move(child, target.appendingPathComponent(child.lastPathComponent))
                }
                try manager.removeItem(at: source)
            } else {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: source, to: target)
            }
        }
        // Moves are retryable: partial progress never replaces a destination file.
        for old in ["Fix macOS", "Mac Utils"] {
            let source = home.appendingPathComponent("Library/Application Support/\(old)")
            let target = home.appendingPathComponent("Library/Application Support/Better macOS")
            if manager.fileExists(atPath: source.path) {
                for child in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                    // Installer checkouts may contain user commits. The installer
                    // manages them; importing feature data never merges Git trees.
                    if child.lastPathComponent == "source" { continue }
                    try move(child, target.appendingPathComponent(child.lastPathComponent))
                }
                if try manager.contentsOfDirectory(atPath: source.path).isEmpty { try manager.removeItem(at: source) }
            }
        }
        try move(home.appendingPathComponent("Library/Logs/Fix macOS"), home.appendingPathComponent("Library/Logs/Better macOS"))
        let logs = home.appendingPathComponent("Library/Logs/Better macOS")
        if manager.fileExists(atPath: logs.path) {
            for file in try manager.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
                where file.lastPathComponent.hasPrefix("fixmacos-") {
                try move(file, logs.appendingPathComponent("bettermacos-" + file.lastPathComponent.dropFirst(9)))
            }
        }
        var values = defaults.persistentDomain(forName: newDomain) ?? [:]
        for (key, value) in defaults.persistentDomain(forName: oldDomain) ?? [:] {
            let renamed = key.replacingOccurrences(of: "FixMacOS.MenuBar.", with: "BetterMacOS.MenuBar.")
            if values[renamed] == nil { values[renamed] = value }
        }
        values[marker] = true
        defaults.setPersistentDomain(values, forName: newDomain)
        guard defaults.synchronize() else {
            throw NSError(domain: "BrandMigration", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not save migrated preferences. Restart Better macOS to retry."])
        }
        // Keep the old preference domain as a recovery copy. Never read it again
        // after the marker, so deleted/new choices cannot be resurrected.
    }
}
