import Foundation

func runBrandMigrationTests() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("better-macos-migration-\(UUID().uuidString)")
    let old = "better-macos.migration.old.\(UUID().uuidString)"
    let new = "better-macos.migration.new.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: new)!
    defer {
        defaults.removePersistentDomain(forName: old); defaults.removePersistentDomain(forName: new)
        try? FileManager.default.removeItem(at: root)
    }
    do {
        let source = root.appendingPathComponent("Library/Application Support/Fix macOS/Clipboard")
        let target = root.appendingPathComponent("Library/Application Support/Better macOS/Clipboard")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("legacy private history".utf8).write(to: source.appendingPathComponent("history.json"))
        try Data("existing new history".utf8).write(to: target.appendingPathComponent("history.json"))
        defaults.setPersistentDomain(["modules.keepAwake": true, "mouse.applied": true,
                                      "NSStatusItem Preferred Position FixMacOS.MenuBar.Toggle": 42], forName: old)
        defaults.setPersistentDomain(["modules.keepAwake": false], forName: new)
        do {
            try BrandMigration.run(home: root, defaults: defaults, oldDomain: old, newDomain: new)
            expect(false, "migration refuses conflicting recovery/history files")
        } catch {
            expect(defaults.persistentDomain(forName: new)?[BrandMigration.marker] == nil,
                   "failed migration leaves completion unset for retry")
            let retained = try String(contentsOf: source.appendingPathComponent("history.json"), encoding: .utf8)
            expect(retained == "legacy private history",
                   "migration conflict retains original history")
        }
        try FileManager.default.removeItem(at: target.appendingPathComponent("history.json"))
        try BrandMigration.run(home: root, defaults: defaults, oldDomain: old, newDomain: new)
        let migrated = try String(contentsOf: target.appendingPathComponent("history.json"), encoding: .utf8)
        expect(migrated == "legacy private history",
               "migration retry moves retained history into the new data directory")
        let values = defaults.persistentDomain(forName: new)!
        expect(values["modules.keepAwake"] as? Bool == false && values["mouse.applied"] as? Bool == true,
               "migration preserves current choices while importing old recovery preferences")
        expect(values["NSStatusItem Preferred Position BetterMacOS.MenuBar.Toggle"] as? Int == 42,
               "migration renames persisted menu-bar position identity")
        defaults.removeObject(forKey: "mouse.applied")
        try BrandMigration.run(home: root, defaults: defaults, oldDomain: old, newDomain: new)
        expect(defaults.object(forKey: "mouse.applied") == nil, "completed migration never resurrects deleted choices")
    } catch { expect(false, "isolated brand migration: \(error)") }
}
