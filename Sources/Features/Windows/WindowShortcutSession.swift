import AppKit

/// Invalidation releases keys, not originals; stop ends the loaded owner's session.
/// Admission and queued-layout cancellation stay owner-owned.
final class WindowShortcutSession {
    struct Target {
        let window: PositionedWindow
        let displays: [WindowDisplay]
        fileprivate let generation: Int
    }
    private let backend: WindowPositionBackend
    private let registration: WindowShortcutRegistering
    private var attempted = false
    private var generation = 0
    private var originalFrames: [String: CGRect] = [:]
    private(set) var active = false
    private(set) var status = "Shortcuts are off."
    private(set) var issue: String?
    var admitsAction: () -> Bool = { false }
    var isExcluded: (String) -> Bool = { _ in true }
    var beforeMove: () -> Void = {}
    var onChange: () -> Void = {}
    var admitsPalette: () -> Bool = { false }
    var onShowActions: () -> Void = {}
    var onInvalidate: () -> Void = {}

    init(backend: WindowPositionBackend, registration: WindowShortcutRegistering) {
        self.backend = backend; self.registration = registration
    }
    func invalidate() {
        generation += 1
        registration.stop(); active = false; attempted = false
        onInvalidate()
        onChange()
    }
    func stop() { invalidate(); originalFrames.removeAll() }
    deinit { registration.stop() }

    func retry(enabled: Bool, admitted: Bool) {
        invalidate(); reconcile(enabled: enabled, admitted: admitted)
    }

    func reconcile(enabled: Bool, admitted: Bool) {
        defer { onChange() }
        guard enabled, admitted else {
            if !admitted || active || attempted { invalidate() }
            status = enabled ? "Waiting for Accessibility access and stable displays." : "Shortcuts are off."
            issue = enabled ? status : nil
            return
        }
        guard !attempted else { return }
        attempted = true
        let ticket = generation
        let registered = registration.start { [weak self] action in
            guard let self, self.generation == ticket, self.active else { return }
            self.perform(action)
        }
        guard generation == ticket else { registration.stop(); return }
        active = registered
        status = active ? "Ready · acts on the focused window." : "Shortcuts unavailable. Quit other window managers, then retry."
        issue = active ? nil : status
    }

    func perform(_ action: WindowShortcutAction) {
        guard active, admitsAction() else { return }
        if action == .showActions { onShowActions(); return }
        _ = execute(action, target: nil)
    }

    func captureTarget() -> Target? {
        guard admitsPalette() else { return nil }
        let ticket = generation
        defer { onChange() }
        do {
            guard let window = try backend.focusedWindow(), window.supported, !isExcluded(window.app),
                  ticket == generation, admitsPalette() else {
                reportIssue("Focus a supported window in an app that is not excluded."); return nil
            }
            let displays = backend.displays()
            guard !displays.isEmpty else { reportIssue("No available destination display."); return nil }
            status = "Choose an action for the focused window."
            issue = nil
            return Target(window: window, displays: displays, generation: ticket)
        } catch { reportIssue("Window discovery failed: \(error.localizedDescription)"); return nil }
    }

    func apply(_ action: WindowShortcutAction, to target: Target) -> Bool {
        execute(action, target: target)
    }

    private func execute(_ action: WindowShortcutAction, target: Target?) -> Bool {
        func admitted() -> Bool {
            if let target { return target.generation == generation && admitsPalette() }
            return active && admitsAction()
        }
        guard action != .showActions, admitted() else { return false }
        defer { onChange() }
        let ticket = generation
        let window: PositionedWindow
        do {
            guard let focused = try backend.focusedWindow(), focused.supported, !isExcluded(focused.app) else {
                reportIssue("Focus a supported window in an app that is not excluded."); return false
            }
            window = focused
        } catch { reportIssue("Window discovery failed: \(error.localizedDescription)"); return false }
        let displays = backend.displays()
        if let target {
            guard window.token == target.window.token, window.app == target.window.app,
                  displays == target.displays else {
                reportIssue("The target window or displays changed. Reopen Window actions."); return false
            }
        }
        guard let frame = action.destination(for: window.frame, displays: displays, original: originalFrames[window.token]) else {
            reportIssue(action == .restore ? "No original size saved for this window." : "No available destination display."); return false
        }
        guard displays == backend.displays(), generation == ticket, admitted() else { return false }
        beforeMove()
        guard generation == ticket, admitted() else { return false }
        if action != .restore && originalFrames[window.token] == nil {
            if originalFrames.count >= 64, let key = originalFrames.keys.sorted().first { originalFrames.removeValue(forKey: key) }
            originalFrames[window.token] = window.frame
        }
        if backend.moveFocused(window, to: frame) {
            if action == .restore { originalFrames.removeValue(forKey: window.token) }
            status = "\(action.title) applied."
            issue = nil
            return true
        } else {
            reportIssue("Window could not reach the requested size or position. The app may limit resizing; try Restore original size.")
            return false
        }
    }
    private func reportIssue(_ message: String) { status = message; issue = message }
}
