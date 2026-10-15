import Foundation

struct ModuleChoiceFailure: Error {
    let detail: String
    let message: String?
}

/// Prepares a persisted enable-choice change, not a universal feature lifecycle.
/// The host admits the request and commits the choice only after success.
/// Like HostTransactions, preparation and its continuations run on the main thread.
struct BuiltinChoicePreparations {
    let keepAwake: KeepAwakeChoicePreparation
    let clipboard: ClipboardChoicePreparation
    let displays: DisplayChoicePreparation

    func prepare(_ module: AppModule, enabled: Bool, completion: @escaping (Result<Void, ModuleChoiceFailure>) -> Void) {
        switch module {
        case .keepAwake where !enabled: completion(keepAwake.prepareDisable())
        case .clipboard where !enabled: completion(clipboard.prepareUnload())
        case .monitors, .arrangement: displays.prepare(module, enabled: enabled, completion: completion)
        default: completion(.success(()))
        }
    }
}

struct KeepAwakeChoicePreparation {
    let owner: () -> KeepAwakeModule?

    func prepareDisable() -> Result<Void, ModuleChoiceFailure> {
        guard let module = owner() else { return .success(()) }
        do { try module.deactivate(); return .success(()) }
        catch {
            // Preserve the same owner and restart observation/retry after refusal.
            module.activate()
            return .failure(ModuleChoiceFailure(detail: error.localizedDescription, message: error.localizedDescription))
        }
    }
}

struct ClipboardChoicePreparation {
    let owner: () -> ClipboardModule?

    func prepareUnload() -> Result<Void, ModuleChoiceFailure> {
        // Unload is not termination: don't stop capture/monitoring on a refusal.
        guard owner()?.history.flushPendingStorage() != false else {
            return .failure(ModuleChoiceFailure(detail: "Clipboard disk cleanup is pending.", message: "Clipboard disk cleanup is pending. Retry after storage becomes available."))
        }
        return .success(())
    }
}

/// One shared display preparation, regardless of which display choice changes.
/// Restoration remains the existing host helper/gesture-drain path.
struct DisplayChoicePreparation {
    let isRecovering: () -> Bool
    let needsRecovery: () -> Bool
    let setStopping: (AppModule, Bool) -> Void
    let restore: (@escaping (Bool) -> Void) -> Void

    func prepare(_ module: AppModule, enabled: Bool, completion: @escaping (Result<Void, ModuleChoiceFailure>) -> Void) {
        guard !isRecovering() else {
            completion(.failure(ModuleChoiceFailure(detail: "Display operation is busy.", message: "Wait for the current display operation to finish.")))
            return
        }
        guard !enabled && needsRecovery() else { completion(.success(())); return }
        setStopping(module, true)
        var completed = false
        restore { restored in
            // A backend must not commit twice or clear a newer operation's marker.
            guard !completed else { return }
            completed = true
            setStopping(module, false)
            if restored { completion(.success(())) }
            else { completion(.failure(ModuleChoiceFailure(detail: "Display restoration failed; recovery remains available.", message: nil))) }
        }
    }
}
