import AppKit

/// Invalidation releases keys, not originals; stop ends the loaded owner's session.
/// Admission and queued-layout cancellation stay owner-owned.
final class WindowShortcutSession {
    private let backend: WindowPositionBackend
    private let registration: WindowShortcutRegistering
    private var attempted = false
    private var generation = 0
    private var originalFrames: [String: CGRect] = [:]
    private(set) var active = false
    private(set) var status = "Shortcuts are off."
    var admitsAction: () -> Bool = { false }
    var isExcluded: (String) -> Bool = { _ in true }
    var beforeMove: () -> Void = {}
    var onChange: () -> Void = {}

    init(backend: WindowPositionBackend, registration: WindowShortcutRegistering) {
        self.backend = backend; self.registration = registration
    }
    func invalidate() {
        generation += 1
        registration.stop(); active = false; attempted = false
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
            invalidate()
            status = enabled ? "Waiting for Accessibility access and stable displays." : "Shortcuts are off."
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
    }

    func perform(_ action: WindowShortcutAction) {
        guard active, admitsAction() else { return }
        defer { onChange() }
        let ticket = generation
        let window: PositionedWindow
        do {
            guard let focused = try backend.focusedWindow(), focused.supported, !isExcluded(focused.app) else {
                status = "Focus a supported window in an app that is not excluded."; return
            }
            window = focused
        } catch { status = "Window discovery failed: \(error.localizedDescription)"; return }
        let displays = backend.displays()
        guard let frame = action.destination(for: window.frame, displays: displays, original: originalFrames[window.token]) else {
            status = action == .restore ? "No original size saved for this window." : "No available destination display."; return
        }
        guard displays == backend.displays(), generation == ticket, active, admitsAction() else { return }
        beforeMove()
        guard generation == ticket, active, admitsAction() else { return }
        if action != .restore && originalFrames[window.token] == nil {
            if originalFrames.count >= 64, let key = originalFrames.keys.sorted().first { originalFrames.removeValue(forKey: key) }
            originalFrames[window.token] = window.frame
        }
        if backend.moveFocused(window, to: frame) {
            if action == .restore { originalFrames.removeValue(forKey: window.token) }
            status = "\(action.title) applied."
        } else {
            status = "Window could not reach the requested size or position. The app may limit resizing; try Restore original size."
        }
    }
}
